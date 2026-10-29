import CryptoKit
import Foundation

nonisolated enum PairingEnd: Equatable, Sendable {
    case committed
    case aborted(PairingAbort)
}

nonisolated enum PairingAbort: Equatable, Sendable {
    case sent(PairAbortReason)
    case received(PairAbortReason)
    case expired
    case cancelledBeforeRequest
    case connectionLost
}

nonisolated enum PairingEffect: Equatable, Sendable {
    case send(BridgeMessage)
    // The wait for the phone's reveal, the step timer's length.
    case armStepTimer
    // The wait for the code to be typed and both confirmations, the confirmation timer's length.
    case armConfirmationTimer
    case commit(peerFingerprint: Data, kBle: Data)
    case close
}

// The Mac's side of the ceremony as a pure state machine: WAITING → REVEALING → CONFIRMING →
// COMMITTED or ABORTED. The caller owns the connection and the timers and carries out the returned
// effects in order. Every exit drops the ephemeral key and the derived secrets.
nonisolated struct MacPairingCeremony {
    enum Phase: Equatable, Sendable {
        case waiting
        case revealing
        // `rejectedEntries` counts the codes typed on this Mac that were not the phone's.
        case confirming(sas: String, localConfirmed: Bool, rejectedEntries: Int)
        case ended(PairingEnd)
    }

    private(set) var phase = Phase.waiting
    private let fpMac: Data
    private var request: (commit: String, fpPhone: Data, key: Curve25519.KeyAgreement.PrivateKey)?
    private var pending: (fpPhone: Data, kBle: Data, confirmKey: Data)?
    private var peerConfirmed = false

    init(fpMac: Data) {
        self.fpMac = fpMac
    }

    var isActive: Bool {
        if case .ended = phase { false } else { true }
    }

    // The Mac's ephemeral key is made only now, after the phone has committed to its own, so the
    // phone's key cannot be chosen with the Mac's in view.
    mutating func receivePairRequest(
        commit: String, fpPhone: Data, ephemeralKey: Curve25519.KeyAgreement.PrivateKey = .init()
    ) -> [PairingEffect] {
        guard phase == .waiting else { return [] }
        guard PairingCrypto.isCommitment(commit) else { return abort(sending: .protocolError) }
        request = (commit, fpPhone, ephemeralKey)
        phase = .revealing
        let publicKey = ephemeralKey.publicKey.rawRepresentation.base64EncodedString()
        return [.send(.pairResponse(publicKey: publicKey)), .armStepTimer]
    }

    mutating func receive(_ message: BridgeMessage) -> [PairingEffect] {
        switch phase {
        case .ended(.committed):
            if case .bye = message { return [.close] }
            return []
        case .ended:
            return []
        case .waiting:
            return abort(sending: .protocolError)
        case .revealing:
            switch message {
            case .pairReveal(let publicKey):
                return reveal(publicKey)
            default:
                return ended(by: message)
            }
        case .confirming(_, let localConfirmed, _):
            switch message {
            // A device in the middle shares another secret with this Mac than with the phone, so it
            // cannot produce the phone's proof.
            case .pairConfirm(let proof):
                guard let pending,
                      PairingCrypto.isValidProof(proof, confirmKey: pending.confirmKey, sender: .phone)
                else { return abort(sending: .protocolError) }
                peerConfirmed = true
                return localConfirmed ? commit() : []
            default:
                return ended(by: message)
            }
        }
    }

    // The code the user typed from the phone's screen is this Mac's confirmation. A wrong one may be
    // typed again until the confirmation timer runs out.
    mutating func enterCode(_ typed: String) -> [PairingEffect] {
        guard case .confirming(let sas, false, let rejected) = phase, let pending else { return [] }
        guard PairingCrypto.codeMatches(typed: typed, sas: sas) else {
            phase = .confirming(sas: sas, localConfirmed: false, rejectedEntries: rejected + 1)
            return []
        }
        phase = .confirming(sas: sas, localConfirmed: true, rejectedEntries: rejected)
        let proof = PairingCrypto.proof(confirmKey: pending.confirmKey, sender: .mac).hex
        return [.send(.pairConfirm(proof: proof))] + (peerConfirmed ? commit() : [])
    }

    mutating func cancel() -> [PairingEffect] {
        switch phase {
        case .waiting:
            end(.aborted(.cancelledBeforeRequest))
            return []
        case .revealing, .confirming:
            return abort(sending: .cancelled)
        case .ended:
            return []
        }
    }

    mutating func timeout() -> [PairingEffect] {
        switch phase {
        case .waiting:
            end(.aborted(.expired))
            return []
        case .revealing, .confirming:
            return abort(sending: .timeout)
        case .ended:
            return []
        }
    }

    mutating func connectionLost() -> [PairingEffect] {
        switch phase {
        case .revealing, .confirming:
            end(.aborted(.connectionLost))
        case .waiting, .ended:
            break
        }
        return []
    }

    private mutating func reveal(_ base64: String) -> [PairingEffect] {
        guard let request,
              let pkPhone = PairingCrypto.publicKey(base64: base64),
              PairingCrypto.revealMatches(commitment: request.commit, publicKey: pkPhone),
              let shared = try? PairingCrypto.sharedSecret(privateKey: request.key, peerPublicKey: pkPhone)
        else { return abort(sending: .protocolError) }
        let secrets = PairingCrypto.derive(
            sharedSecret: shared,
            transcript: PairingCrypto.transcript(
                fpMac: fpMac, fpPhone: request.fpPhone, pkMac: request.key.publicKey.rawRepresentation, pkPhone: pkPhone
            )
        )
        self.request = nil
        pending = (request.fpPhone, secrets.kBle, secrets.confirmKey)
        phase = .confirming(sas: secrets.sas, localConfirmed: false, rejectedEntries: 0)
        return [.armConfirmationTimer]
    }

    private mutating func ended(by message: BridgeMessage) -> [PairingEffect] {
        switch message {
        case .pairAbort(let reason):
            end(.aborted(.received(PairAbortReason(wire: reason))))
            return [.close]
        case .bye:
            end(.aborted(.connectionLost))
            return [.close]
        default:
            return abort(sending: .protocolError)
        }
    }

    private mutating func commit() -> [PairingEffect] {
        guard let pending else { return abort(sending: .protocolError) }
        end(.committed)
        return [.commit(peerFingerprint: pending.fpPhone, kBle: pending.kBle)]
    }

    private mutating func abort(sending reason: PairAbortReason) -> [PairingEffect] {
        end(.aborted(.sent(reason)))
        return [.send(.pairAbort(reason)), .close]
    }

    private mutating func end(_ result: PairingEnd) {
        request = nil
        pending = nil
        peerConfirmed = false
        phase = .ended(result)
    }
}
