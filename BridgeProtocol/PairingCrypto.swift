import CryptoKit
import Foundation

nonisolated enum PairingCryptoError: Error, Equatable {
    case badPublicKey
    case zeroSharedSecret
}

nonisolated struct PairingSecrets: Equatable, Sendable {
    var transcriptHash: Data
    var kBle: Data
    var sasOkm: Data
    var sas: String
    var confirmKey: Data
}

nonisolated enum PairingRole: String, Sendable {
    case phone
    case mac
}

nonisolated enum PairingCrypto {
    static let commitLabel = "app.cue.bridge/commit/v1"
    static let transcriptLabel = "app.cue.bridge/pair/v1"
    static let kBleLabel = "app.cue.bridge/kble/v1"
    static let sasLabel = "app.cue.bridge/sas/v1"
    static let confirmLabel = "app.cue.bridge/confirm/v1"

    static func publicKey(base64: String) -> Data? {
        guard let key = Data(base64Encoded: base64), key.count == 32 else { return nil }
        return key
    }

    // CryptoKit accepts any 32 bytes as a public key, so a failed agreement can only come from a
    // low-order point; an all-zero result that it returns instead is caught below.
    static func sharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKey: Data
    ) throws(PairingCryptoError) -> SymmetricKey {
        let peer: Curve25519.KeyAgreement.PublicKey
        do {
            peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        } catch {
            throw .badPublicKey
        }
        let shared: SharedSecret
        do {
            shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw .zeroSharedSecret
        }
        // Straight into the key's zeroed-on-release storage, with no Data copy of the secret left behind.
        let secret = shared.withUnsafeBytes { bytes -> SymmetricKey? in
            guard bytes.count == 32, bytes.contains(where: { $0 != 0 }) else { return nil }
            return SymmetricKey(data: bytes)
        }
        guard let secret else { throw .zeroSharedSecret }
        return secret
    }

    static func proof(confirmKey: Data, sender: PairingRole) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(sender.rawValue.utf8), using: SymmetricKey(data: confirmKey)))
    }

    // Lowercase hex only, compared in constant time by CryptoKit.
    static func isValidProof(_ hex: String, confirmKey: Data, sender: PairingRole) -> Bool {
        guard Fingerprint.isWellFormed(hex), let proof = Data(hex: hex) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: Data(sender.rawValue.utf8), using: SymmetricKey(data: confirmKey)
        )
    }

    static func commitment(to phonePublicKey: Data) -> Data {
        Data(SHA256.hash(data: lengthPrefixed([Data(commitLabel.utf8), phonePublicKey])))
    }

    // A commitment is 64 lowercase hex digits, like a fingerprint; the revealed key must be the one it
    // was made to, compared in constant time.
    static func isCommitment(_ hex: String) -> Bool {
        Fingerprint.isWellFormed(hex)
    }

    static func revealMatches(commitment hex: String, publicKey: Data) -> Bool {
        guard isCommitment(hex), let committed = Data(hex: hex) else { return false }
        return constantTimeEqual(committed, commitment(to: publicKey))
    }

    // The digits the Mac's user typed against the code the Mac derived, in constant time.
    static func codeMatches(typed: String, sas: String) -> Bool {
        let typed = Data(typed.utf8)
        let expected = Data(sas.utf8)
        return typed.count == expected.count && constantTimeEqual(typed, expected)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) {
            difference |= x ^ y
        }
        return difference == 0
    }

    static func transcript(fpMac: Data, fpPhone: Data, pkMac: Data, pkPhone: Data) -> Data {
        lengthPrefixed([Data(transcriptLabel.utf8), fpMac, fpPhone, pkMac, pkPhone])
    }

    static func lengthPrefixed(_ parts: [Data]) -> Data {
        var out = Data()
        for part in parts {
            out.appendUInt16(UInt16(part.count))
            out.append(part)
        }
        return out
    }

    static func derive(sharedSecret: SymmetricKey, transcript: Data) -> PairingSecrets {
        let transcriptHash = Data(SHA256.hash(data: transcript))
        let kBle = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret, salt: transcriptHash, info: Data(kBleLabel.utf8), outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let sasOkm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret, salt: transcriptHash, info: Data(sasLabel.utf8), outputByteCount: 4
        ).withUnsafeBytes { Data($0) }
        let confirmKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret, salt: transcriptHash, info: Data(confirmLabel.utf8), outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        let code = sasOkm.uint32(at: 0) % 1_000_000
        let sas = String(repeating: "0", count: 6 - String(code).count) + String(code)
        return PairingSecrets(
            transcriptHash: transcriptHash, kBle: kBle, sasOkm: sasOkm, sas: sas, confirmKey: confirmKey
        )
    }
}
