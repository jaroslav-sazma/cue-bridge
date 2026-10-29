import Foundation
import Testing

// The vectors are a vendored copy of the launcher repo's canonical fixtures/bridge/
// (tools/sync-vectors.sh). From xcodebuild an environment variable reaches the tests only with the
// TEST_RUNNER_ prefix: BRIDGE_VECTORS_DIR moves the vectors read, BRIDGE_LAUNCHER_DIR the launcher
// checkout that the parity check and the spec tests look for; a path without a launcher in it
// stands for a standalone clone.
nonisolated enum Vectors {
    static let defaultLauncherPath = "../../Android/Launcher"

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static let vendored = repoRoot.appending(path: "fixtures/bridge", directoryHint: .isDirectory)

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BRIDGE_VECTORS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        }
        return vendored
    }

    static let launcher: URL? = {
        let configured = ProcessInfo.processInfo.environment["BRIDGE_LAUNCHER_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let root = configured.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? repoRoot.appending(path: defaultLauncherPath, directoryHint: .isDirectory)
        let spec = root.appending(path: "docs/bridge-protocol.md").path
        return FileManager.default.fileExists(atPath: spec) ? root.standardizedFileURL : nil
    }()

    static func spec() throws -> String {
        let launcher = try #require(launcher)
        return try String(contentsOf: launcher.appending(path: "docs/bridge-protocol.md"), encoding: .utf8)
    }

    static func load<T: Decodable>(_ type: T.Type, from file: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: directory.appending(path: file)))
    }

    // Parameterized tests need their arguments without throwing; a missing file yields no cases
    // here and fails VectorFileTests instead.
    static func cases<T: Decodable, Case>(_ type: T.Type, from file: String, _ pick: (T) -> [Case]) -> [Case] {
        (try? load(type, from: file)).map(pick) ?? []
    }

    static let chacha = cases(ChaChaFile.self, from: "chacha20poly1305.json") { $0.vectors }
    static let x25519 = try? load(X25519File.self, from: "x25519.json")
    static let hkdf = cases(HkdfFile.self, from: "hkdf.json") { $0.vectors }
    static let pairing = try? load(PairingFile.self, from: "pairing.json")
    static let frames = try? load(FramesFile.self, from: "frames.json")
    static let messages = try? load(MessagesFile.self, from: "messages.json")
    static let stateSync = try? load(StateSyncFile.self, from: "state-sync.json")
    static let l2cap = try? load(L2capFile.self, from: "l2cap.json")
}

nonisolated extension Data {
    init(vectorHex hex: String) {
        guard let data = Data(hex: hex) else { preconditionFailure("vector hex is malformed: \(hex)") }
        self = data
    }
}

nonisolated struct ChaChaFile: Decodable, Sendable {
    struct Vector: Decodable, Sendable, CustomTestStringConvertible {
        var source, key, nonce, aad, plaintext, ciphertext, tag: String
        var testDescription: String { source }
    }

    var vectors: [Vector]
}

nonisolated struct X25519File: Decodable, Sendable {
    struct ScalarMult: Decodable, Sendable, CustomTestStringConvertible {
        var source, scalar, u, output: String
        var testDescription: String { source }
    }

    struct Iterated: Decodable, Sendable, CustomTestStringConvertible {
        var source, start, output: String
        var iterations: Int
        var testDescription: String { source }
    }

    struct DiffieHellman: Decodable, Sendable, CustomTestStringConvertible {
        var source, alicePrivate, alicePublic, bobPrivate, bobPublic, shared: String
        var testDescription: String { source }
    }

    var scalarMult: [ScalarMult]
    var iterated: [Iterated]
    var diffieHellman: [DiffieHellman]
}

nonisolated struct HkdfFile: Decodable, Sendable {
    struct Vector: Decodable, Sendable, CustomTestStringConvertible {
        var source, ikm, salt, info, prk, okm: String
        var length: Int
        var testDescription: String { source }
    }

    var vectors: [Vector]
}

nonisolated struct PairingFile: Decodable, Sendable {
    struct Labels: Decodable, Sendable {
        var commit, transcript, kBle, sas, confirm: String
    }

    struct Certificate: Decodable, Sendable, CustomTestStringConvertible {
        var name, der, fingerprint: String
        var testDescription: String { name }
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var macPrivateKey, macPublicKey, macPublicKeyBase64: String
        var phonePrivateKey, phonePublicKey, phonePublicKeyBase64: String
        var macFingerprint, phoneFingerprint: String
        var sharedSecret, transcript, transcriptHash, kBle, sasOkm, sas: String
        var confirmKey, proofPhone, proofMac: String
        var commitInput, commit: String
        var testDescription: String { name }
    }

    struct LowOrderKey: Decodable, Sendable, CustomTestStringConvertible {
        var name, publicKey, expect: String
        var testDescription: String { name }
    }

    struct CommitCheck: Decodable, Sendable, CustomTestStringConvertible {
        var name, commit, revealedKey, expect: String
        var testDescription: String { name }
    }

    struct CeremonyMessage: Decodable, Sendable {
        var from, body: String
    }

    struct Ceremony: Decodable, Sendable, CustomTestStringConvertible {
        var name, `case`, expect: String
        var checks: [String]
        var messages: [CeremonyMessage]
        var sas, kBle: String?
        var testDescription: String { name }
    }

    struct AbortReason: Decodable, Sendable, CustomTestStringConvertible {
        var wire, reads: String
        var testDescription: String { wire }
    }

    var labels: Labels
    var certificates: [Certificate]
    var cases: [Case]
    var lowOrderPublicKeys: [LowOrderKey]
    var commitChecks: [CommitCheck]
    var ceremonies: [Ceremony]
    var abortReasons: [AbortReason]
}

nonisolated struct FramesFile: Decodable, Sendable {
    struct KeyHash: Decodable, Sendable, CustomTestStringConvertible {
        var key, hash: String
        var testDescription: String { "key \"\(key)\"" }
    }

    struct Vector: Decodable, Sendable, CustomTestStringConvertible {
        var name, direction, plaintext, nonce, frame, signal: String
        var seq: UInt32
        var type: UInt8
        var testDescription: String { name }
    }

    struct Rejection: Decodable, Sendable, CustomTestStringConvertible {
        var name, direction, frame, expect, reason: String
        var accepted: [UInt32]
        var testDescription: String { name }
    }

    struct WindowCase: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var offered: [UInt32]
        var expect: [String]
        var testDescription: String { name }
    }

    struct Window: Decodable, Sendable {
        var size: UInt32
        var cases: [WindowCase]
    }

    var kBle: String
    var maxFrameBytes: Int
    var keyHashes: [KeyHash]
    var vectors: [Vector]
    var rejections: [Rejection]
    var replayWindow: Window
}

nonisolated struct MessagesFile: Decodable, Sendable {
    struct Example: Decodable, Sendable, CustomTestStringConvertible {
        var type, body, frame: String
        var binary: String?
        var testDescription: String { type }
    }

    struct Expectation: Decodable, Sendable, Equatable {
        var result: String
        var type: String?
    }

    struct Stream: Decodable, Sendable, CustomTestStringConvertible {
        var name, stream: String
        var expect: [Expectation]
        var testDescription: String { name }
    }

    var bridgeProtocolVersion: Int
    var maxBodyBytes: Int
    var maxBinaryBytes: Int
    var examples: [Example]
    var streams: [Stream]
}

nonisolated struct StateSyncFile: Decodable, Sendable {
    struct Expectation: Decodable, Sendable {
        var added, updated, removed, untouched: [String]
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        var name: String
        var mirror: [NotificationInfo]
        var activeSet: [NotificationInfo]
        var expect: Expectation
        var testDescription: String { name }
    }

    var renderedFields: [String]
    var cases: [Case]
}

nonisolated struct L2capFile: Decodable, Sendable {
    struct Derivation: Decodable, Sendable, CustomTestStringConvertible {
        var name, kBle, phonePrivateKey, phonePublicKey, macPublicKey, expect: String
        var macPrivateKey, sharedSecret, salt, okm, phoneToMacKey, macToPhoneKey: String?
        var testDescription: String { name }
    }

    struct Seal: Decodable, Sendable, CustomTestStringConvertible {
        var name, key, nonce: String
        var counter: UInt64
        var plaintext, record: String?
        var plaintextPattern: String?
        var plaintextBytes, recordBytes: Int?
        var recordHead, tag, recordSha256: String?
        var testDescription: String { name }
    }

    struct Failure: Decodable, Sendable, CustomTestStringConvertible {
        var name, key, stream, expect, reason: String
        var counter: UInt64
        var zeroFill: Int?
        var testDescription: String { name }
    }

    struct Records: Decodable, Sendable {
        var seals: [Seal]
        var failures: [Failure]
    }

    struct Write: Decodable, Sendable {
        var what, bytes: String
        var counter: UInt64?
        var plaintext: String?
    }

    struct Transcript: Decodable, Sendable {
        var name, kBle: String
        var phonePrivateKey, phonePublicKey, macPrivateKey, macPublicKey: String
        var sharedSecret, salt, phoneToMacKey, macToPhoneKey: String
        var phoneWrites, macWrites: [Write]
        var phoneStream, macStream: String
        var phoneBodies, macBodies: [String]
    }

    var label: String
    var handshakeKeyBytes, maxPlaintextBytes, minCiphertextBytes, maxCiphertextBytes, timeoutMs: Int
    var derivation: [Derivation]
    var records: Records
    var transcript: Transcript
}

nonisolated func direction(_ name: String) -> SignalDirection {
    switch name {
    case "phone-to-mac": .phoneToMac
    case "mac-to-phone": .macToPhone
    default: preconditionFailure("unknown direction \(name)")
    }
}
