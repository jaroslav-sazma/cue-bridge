import CryptoKit
import Foundation
import Security
import Testing

@Suite("pairing.json")
struct PairingVectorTests {
    @Test("the derivation labels match the Swift constants")
    func labels() throws {
        let labels = try #require(Vectors.pairing).labels
        #expect(labels.commit == PairingCrypto.commitLabel)
        #expect(labels.transcript == PairingCrypto.transcriptLabel)
        #expect(labels.kBle == PairingCrypto.kBleLabel)
        #expect(labels.sas == PairingCrypto.sasLabel)
        #expect(labels.confirm == PairingCrypto.confirmLabel)
    }

    @Test(arguments: Vectors.pairing?.certificates ?? [])
    func certificateFingerprint(_ certificate: PairingFile.Certificate) {
        let der = Data(vectorHex: certificate.der)
        #expect(Fingerprint.of(certificateDER: der).hex == certificate.fingerprint)
        #expect(SecCertificateCreateWithData(nil, der as CFData) != nil)
    }

    @Test(arguments: Vectors.pairing?.cases ?? [])
    func derivation(_ vector: PairingFile.Case) throws {
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: vector.macPrivateKey))
        let phone = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: vector.phonePrivateKey))
        #expect(mac.publicKey.rawRepresentation.hex == vector.macPublicKey)
        #expect(phone.publicKey.rawRepresentation.hex == vector.phonePublicKey)
        #expect(mac.publicKey.rawRepresentation.base64EncodedString() == vector.macPublicKeyBase64)
        #expect(phone.publicKey.rawRepresentation.base64EncodedString() == vector.phonePublicKeyBase64)
        #expect(PairingCrypto.publicKey(base64: vector.phonePublicKeyBase64)?.hex == vector.phonePublicKey)

        // The commitment recomputed straight from CryptoKit as well as through PairingCrypto.
        let pkPhone = Data(vectorHex: vector.phonePublicKey)
        var input = Data([0, UInt8(PairingCrypto.commitLabel.utf8.count)]) + Data(PairingCrypto.commitLabel.utf8)
        input += Data([0, 32]) + pkPhone
        #expect(input.hex == vector.commitInput)
        #expect(Data(SHA256.hash(data: input)).hex == vector.commit)
        #expect(PairingCrypto.commitment(to: pkPhone).hex == vector.commit)

        let fromMac = try PairingCrypto.sharedSecret(privateKey: mac, peerPublicKey: Data(vectorHex: vector.phonePublicKey))
        let fromPhone = try PairingCrypto.sharedSecret(privateKey: phone, peerPublicKey: Data(vectorHex: vector.macPublicKey))
        #expect(fromMac.withUnsafeBytes { Data($0) }.hex == vector.sharedSecret)
        #expect(fromPhone.withUnsafeBytes { Data($0) }.hex == vector.sharedSecret)

        let transcript = PairingCrypto.transcript(
            fpMac: Data(vectorHex: vector.macFingerprint), fpPhone: Data(vectorHex: vector.phoneFingerprint),
            pkMac: Data(vectorHex: vector.macPublicKey), pkPhone: Data(vectorHex: vector.phonePublicKey)
        )
        #expect(transcript.count == 160)
        #expect(transcript.hex == vector.transcript)

        let secrets = PairingCrypto.derive(sharedSecret: fromMac, transcript: transcript)
        #expect(secrets.transcriptHash.hex == vector.transcriptHash)
        #expect(secrets.kBle.hex == vector.kBle)
        #expect(secrets.sasOkm.hex == vector.sasOkm)
        #expect(secrets.sas == vector.sas)

        // Recomputed straight from CryptoKit, not through PairingCrypto, as the cross-check.
        let confirmKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: fromPhone, salt: Data(SHA256.hash(data: transcript)),
            info: Data("app.cue.bridge/confirm/v1".utf8), outputByteCount: 32
        )
        #expect(confirmKey.withUnsafeBytes { Data($0) }.hex == vector.confirmKey)
        #expect(secrets.confirmKey.hex == vector.confirmKey)
        #expect(Data(HMAC<SHA256>.authenticationCode(for: Data("phone".utf8), using: confirmKey)).hex == vector.proofPhone)
        #expect(Data(HMAC<SHA256>.authenticationCode(for: Data("mac".utf8), using: confirmKey)).hex == vector.proofMac)
        #expect(PairingCrypto.proof(confirmKey: secrets.confirmKey, sender: .phone).hex == vector.proofPhone)
        #expect(PairingCrypto.proof(confirmKey: secrets.confirmKey, sender: .mac).hex == vector.proofMac)
        #expect(PairingCrypto.isValidProof(vector.proofPhone, confirmKey: secrets.confirmKey, sender: .phone))
        #expect(!PairingCrypto.isValidProof(vector.proofMac, confirmKey: secrets.confirmKey, sender: .phone))
    }

    @Test(arguments: Vectors.pairing?.commitChecks ?? [])
    func commitCheck(_ vector: PairingFile.CommitCheck) {
        let key = PairingCrypto.publicKey(base64: vector.revealedKey)
        let outcome = if !PairingCrypto.isCommitment(vector.commit) || key == nil {
            "invalid"
        } else if PairingCrypto.revealMatches(commitment: vector.commit, publicKey: key!) {
            "valid"
        } else {
            "mismatch"
        }
        #expect(outcome == vector.expect)
    }

    // The ceremony's own answer to every commit check: only a valid reveal gets to the code.
    @Test(arguments: Vectors.pairing?.commitChecks ?? [])
    func ceremonyRevealCheck(_ vector: PairingFile.CommitCheck) throws {
        var ceremony = MacPairingCeremony(fpMac: Data(repeating: 0xaa, count: 32))
        let request = ceremony.receivePairRequest(commit: vector.commit, fpPhone: Data(repeating: 0xbb, count: 32))
        guard PairingCrypto.isCommitment(vector.commit) else {
            #expect(request == [.send(.pairAbort(.protocolError)), .close])
            return
        }
        let reveal = ceremony.receive(.pairReveal(publicKey: vector.revealedKey))
        if vector.expect == "valid" {
            #expect(reveal == [.armConfirmationTimer])
            guard case .confirming = ceremony.phase else {
                Issue.record("a valid reveal did not reach the code")
                return
            }
        } else {
            #expect(reveal == [.send(.pairAbort(.protocolError)), .close])
            #expect(ceremony.phase == .ended(.aborted(.sent(.protocolError))))
        }
    }

    @Test(arguments: Vectors.pairing?.abortReasons ?? [])
    func abortReason(_ vector: PairingFile.AbortReason) {
        #expect(PairAbortReason(wire: vector.wire).rawValue == vector.reads)
    }

    // The Mac's side of every vector conversation in which the Mac is the honest party: the phone's
    // messages go in, and what the Mac sends has to be the vector's next Mac message. The user types
    // the code where the Mac's pair-confirm is due and nothing else is queued. Hellos and the busy
    // answer belong to the connection, not the ceremony, so they run through LinkMachine.
    @Test(arguments: (Vectors.pairing?.ceremonies ?? []).filter { $0.checks.contains("mac") })
    func macCeremony(_ vector: PairingFile.Ceremony) throws {
        let cases = try #require(Vectors.pairing?.cases)
        let keys = try #require(cases.first { $0.name == vector.case })
        let decode = { (body: String) in
            try #require(try BridgeMessage.decode(type: Self.messageType(of: body), body: Data(body.utf8), sidecar: nil))
        }
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: keys.macPrivateKey))
        let fpPhone = Data(vectorHex: keys.phoneFingerprint)
        var link = LinkMachine()
        var ceremony = MacPairingCeremony(fpMac: Data(vectorHex: keys.macFingerprint))
        let context = LinkContext(isPinned: false, ceremony: vector.expect == "busy" ? .busy : .open, lastPairingModeExpired: false)
        var outgoing = link.connection(.ready(hasPeerCertificate: true)).compactMap(Self.sent)
        var committed: Data?
        for step in vector.messages {
            let message = try decode(step.body)
            if step.from == "phone" {
                var effects: [PairingEffect] = []
                for linkEffect in link.received(message, context: context) {
                    switch linkEffect {
                    case .send(let reply): outgoing.append(reply)
                    case .beginPairing(let commit):
                        effects += ceremony.receivePairRequest(commit: commit, fpPhone: fpPhone, ephemeralKey: mac)
                    case .toCeremony(let inner): effects += ceremony.receive(inner)
                    default: break
                    }
                }
                outgoing += effects.compactMap(Self.sent)
                committed = committed ?? Self.committedKey(effects)
            } else {
                if outgoing.isEmpty, case .pairConfirm = message {
                    let effects = ceremony.enterCode(try #require(vector.sas))
                    outgoing += effects.compactMap(Self.sent)
                    committed = committed ?? Self.committedKey(effects)
                }
                #expect(outgoing.first == message, "the Mac's next message")
                if !outgoing.isEmpty { outgoing.removeFirst() }
            }
        }
        #expect(outgoing.isEmpty, "the Mac sent more: \(outgoing)")
        switch vector.expect {
        case "committed":
            #expect(ceremony.phase == .ended(.committed))
            #expect(committed?.hex == vector.kBle)
        case "busy":
            #expect(ceremony.phase == .waiting)
        default:
            #expect(ceremony.phase == .ended(.aborted(.sent(.protocolError))))
        }
    }

    @Test(arguments: Vectors.pairing?.lowOrderPublicKeys ?? [])
    func lowOrderPublicKey(_ vector: PairingFile.LowOrderKey) throws {
        #expect(vector.expect == "zero-shared-secret")
        let first = try #require(Vectors.pairing?.cases.first)
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: first.macPrivateKey))
        #expect(throws: PairingCryptoError.zeroSharedSecret) {
            try PairingCrypto.sharedSecret(privateKey: mac, peerPublicKey: Data(vectorHex: vector.publicKey))
        }
        let publicKey = Data(vectorHex: vector.publicKey)
        var ceremony = MacPairingCeremony(fpMac: Data(vectorHex: first.macFingerprint))
        _ = ceremony.receivePairRequest(
            commit: PairingCrypto.commitment(to: publicKey).hex, fpPhone: Data(vectorHex: first.phoneFingerprint),
            ephemeralKey: mac
        )
        #expect(ceremony.receive(.pairReveal(publicKey: publicKey.base64EncodedString())) == [.send(.pairAbort(.protocolError)), .close])
    }

    private static func messageType(of body: String) throws -> String {
        let object = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
        return try #require(object?["type"] as? String)
    }

    private static func sent(_ effect: PairingEffect) -> BridgeMessage? {
        if case .send(let message) = effect { message } else { nil }
    }

    private static func sent(_ effect: LinkEffect) -> BridgeMessage? {
        if case .send(let message) = effect { message } else { nil }
    }

    private static func committedKey(_ effects: [PairingEffect]) -> Data? {
        for effect in effects {
            if case .commit(_, let kBle) = effect { return kBle }
        }
        return nil
    }
}

@Suite("Mac pairing ceremony")
struct MacPairingCeremonyTests {
    private static let fpMac = Data(repeating: 0xaa, count: 32)
    private static let fpPhone = Data(repeating: 0xbb, count: 32)
    private static let phoneKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

    private func revealing() -> MacPairingCeremony {
        var ceremony = MacPairingCeremony(fpMac: Self.fpMac)
        _ = ceremony.receivePairRequest(commit: PairingCrypto.commitment(to: Self.phoneKey).hex, fpPhone: Self.fpPhone)
        return ceremony
    }

    private func confirming() -> MacPairingCeremony {
        var ceremony = revealing()
        _ = ceremony.receive(.pairReveal(publicKey: Self.phoneKey.base64EncodedString()))
        return ceremony
    }

    private func confirmingVector() throws -> (MacPairingCeremony, PairingFile.Case) {
        let vector = try #require(Vectors.pairing?.cases.first)
        let mac = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: vector.macPrivateKey))
        var ceremony = MacPairingCeremony(fpMac: Data(vectorHex: vector.macFingerprint))
        _ = ceremony.receivePairRequest(
            commit: vector.commit, fpPhone: Data(vectorHex: vector.phoneFingerprint), ephemeralKey: mac
        )
        _ = ceremony.receive(.pairReveal(publicKey: vector.phonePublicKeyBase64))
        return (ceremony, vector)
    }

    @Test("the Mac's key leaves only after the phone's commitment, and fresh for each ceremony")
    func keyAfterCommitment() throws {
        var first = MacPairingCeremony(fpMac: Self.fpMac)
        var second = MacPairingCeremony(fpMac: Self.fpMac)
        let commit = PairingCrypto.commitment(to: Self.phoneKey).hex
        let one = first.receivePairRequest(commit: commit, fpPhone: Self.fpPhone)
        let two = second.receivePairRequest(commit: commit, fpPhone: Self.fpPhone)
        guard case .send(.pairResponse(let a)) = one.first, case .send(.pairResponse(let b)) = two.first else {
            Issue.record("no pair-response")
            return
        }
        #expect(a != b)
        #expect(one.last == .armStepTimer)
        #expect(first.phase == .revealing)
    }

    @Test("the right code commits once the phone has confirmed, in either order")
    func rightCode() throws {
        var (ceremony, vector) = try confirmingVector()
        let commit = PairingEffect.commit(
            peerFingerprint: Data(vectorHex: vector.phoneFingerprint), kBle: Data(vectorHex: vector.kBle)
        )
        #expect(ceremony.phase == .confirming(sas: vector.sas, localConfirmed: false, rejectedEntries: 0))
        #expect(ceremony.enterCode(vector.sas) == [.send(.pairConfirm(proof: vector.proofMac))])
        #expect(ceremony.receive(.pairConfirm(proof: vector.proofPhone)) == [commit])

        var (peerFirst, _) = try confirmingVector()
        #expect(peerFirst.receive(.pairConfirm(proof: vector.proofPhone)).isEmpty)
        #expect(peerFirst.enterCode(vector.sas) == [.send(.pairConfirm(proof: vector.proofMac)), commit])
    }

    // The Mac confirms only what its user typed from the phone: a wrong code sends nothing, leaves the
    // ceremony waiting and can be typed again.
    @Test("a wrong code is refused and may be typed again", arguments: ["one digit off", "too short", "not digits", "empty"])
    func wrongCode(_ kind: String) throws {
        var (ceremony, vector) = try confirmingVector()
        let lastDigit = (Int(String(vector.sas.last!))! + 1) % 10
        let wrong = [
            "one digit off": String(vector.sas.dropLast()) + String(lastDigit),
            "too short": String(vector.sas.dropLast()),
            "not digits": "abcdef",
            "empty": "",
        ]
        #expect(ceremony.enterCode(try #require(wrong[kind])).isEmpty)
        #expect(ceremony.phase == .confirming(sas: vector.sas, localConfirmed: false, rejectedEntries: 1))
        #expect(ceremony.receive(.pairConfirm(proof: vector.proofPhone)).isEmpty)
        #expect(ceremony.enterCode(vector.sas).first == .send(.pairConfirm(proof: vector.proofMac)))
        #expect(ceremony.phase == .ended(.committed))
    }

    @Test("the code compare is exact")
    func codeCompare() {
        #expect(PairingCrypto.codeMatches(typed: "013112", sas: "013112"))
        #expect(!PairingCrypto.codeMatches(typed: "13112", sas: "013112"))
        #expect(!PairingCrypto.codeMatches(typed: "0131120", sas: "013112"))
        #expect(!PairingCrypto.codeMatches(typed: "013 112", sas: "013112"))
    }

    // A device in the middle shares another secret with this Mac than with the phone, so it cannot
    // produce the phone's proof: its pair-confirm aborts even after the right code was typed here.
    @Test(
        "a pair-confirm without the phone's proof aborts with protocol-error",
        arguments: ["reflected Mac proof", "another pairing", "uppercase", "short", "empty"], [true, false]
    )
    func badProof(_ kind: String, localFirst: Bool) throws {
        var (ceremony, vector) = try confirmingVector()
        let proofs = [
            "reflected Mac proof": vector.proofMac,
            "another pairing": try #require(Vectors.pairing?.cases.last).proofPhone,
            "uppercase": vector.proofPhone.uppercased(),
            "short": String(vector.proofPhone.dropLast(2)),
            "empty": "",
        ]
        if localFirst { _ = ceremony.enterCode(vector.sas) }
        #expect(
            ceremony.receive(.pairConfirm(proof: try #require(proofs[kind])))
                == [.send(.pairAbort(.protocolError)), .close]
        )
        #expect(ceremony.phase == .ended(.aborted(.sent(.protocolError))))
        #expect(ceremony.enterCode(vector.sas).isEmpty)
    }

    @Test("a commitment that is not 64 lowercase hex digits aborts with protocol-error")
    func badCommitment() {
        var ceremony = MacPairingCeremony(fpMac: Self.fpMac)
        #expect(
            ceremony.receivePairRequest(commit: "AAAA", fpPhone: Self.fpPhone)
                == [.send(.pairAbort(.protocolError)), .close]
        )
        #expect(ceremony.phase == .ended(.aborted(.sent(.protocolError))))
    }

    @Test("a reveal of another key, or of a key that is not 32 bytes, aborts with protocol-error")
    func badReveal() {
        for key in [Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString(), "AAAA"] {
            var ceremony = revealing()
            #expect(ceremony.receive(.pairReveal(publicKey: key)) == [.send(.pairAbort(.protocolError)), .close])
            #expect(ceremony.phase == .ended(.aborted(.sent(.protocolError))))
        }
    }

    @Test("an out-of-order message aborts with protocol-error")
    func outOfOrder() {
        var early = revealing()
        #expect(early.receive(.pairConfirm(proof: String(repeating: "0", count: 64))) == [.send(.pairAbort(.protocolError)), .close])
        var late = confirming()
        #expect(late.receive(.pairReveal(publicKey: Self.phoneKey.base64EncodedString())) == [.send(.pairAbort(.protocolError)), .close])
        var waiting = MacPairingCeremony(fpMac: Self.fpMac)
        #expect(waiting.receive(.pairReveal(publicKey: Self.phoneKey.base64EncodedString())) == [.send(.pairAbort(.protocolError)), .close])
    }

    @Test("the phone's pair-abort ends the ceremony; an unknown reason counts as cancelled")
    func peerAbort() {
        var ceremony = confirming()
        #expect(ceremony.receive(.pairAbort(reason: "something-new")) == [.close])
        #expect(ceremony.phase == .ended(.aborted(.received(.cancelled))))
        var revealing = revealing()
        #expect(revealing.receive(.pairAbort(reason: "cancelled")) == [.close])
        #expect(revealing.phase == .ended(.aborted(.received(.cancelled))))
    }

    @Test("timeouts: pairing mode without a phone ends quietly, a waiting ceremony sends timeout")
    func timeouts() {
        var open = MacPairingCeremony(fpMac: Self.fpMac)
        #expect(open.timeout().isEmpty)
        #expect(open.phase == .ended(.aborted(.expired)))
        var revealing = revealing()
        #expect(revealing.timeout() == [.send(.pairAbort(.timeout)), .close])
        var waiting = confirming()
        #expect(waiting.timeout() == [.send(.pairAbort(.timeout)), .close])
    }

    @Test("a lost connection aborts and later events change nothing")
    func connectionLost() {
        var ceremony = confirming()
        #expect(ceremony.connectionLost().isEmpty)
        #expect(ceremony.phase == .ended(.aborted(.connectionLost)))
        #expect(ceremony.enterCode("000000").isEmpty)
        #expect(ceremony.receive(.pairConfirm(proof: "")).isEmpty)
        var revealing = revealing()
        #expect(revealing.connectionLost().isEmpty)
        #expect(revealing.phase == .ended(.aborted(.connectionLost)))
    }

    @Test("a second pair-request does not restart the ceremony")
    func secondRequest() {
        var ceremony = confirming()
        #expect(ceremony.receivePairRequest(commit: PairingCrypto.commitment(to: Self.phoneKey).hex, fpPhone: Self.fpPhone).isEmpty)
    }
}
