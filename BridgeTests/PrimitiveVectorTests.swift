import CryptoKit
import Foundation
import Testing

@Suite("Vector files")
struct VectorFileTests {
    @Test("every vector file loads and is non-empty")
    func filesLoad() throws {
        #expect(try !Vectors.load(ChaChaFile.self, from: "chacha20poly1305.json").vectors.isEmpty)
        let x25519 = try Vectors.load(X25519File.self, from: "x25519.json")
        #expect(!x25519.scalarMult.isEmpty && !x25519.iterated.isEmpty && !x25519.diffieHellman.isEmpty)
        #expect(try !Vectors.load(HkdfFile.self, from: "hkdf.json").vectors.isEmpty)
        let pairing = try Vectors.load(PairingFile.self, from: "pairing.json")
        #expect(!pairing.cases.isEmpty && !pairing.certificates.isEmpty)
        #expect(!pairing.commitChecks.isEmpty && !pairing.ceremonies.isEmpty && !pairing.abortReasons.isEmpty)
        let frames = try Vectors.load(FramesFile.self, from: "frames.json")
        #expect(!frames.vectors.isEmpty && !frames.rejections.isEmpty && !frames.keyHashes.isEmpty)
        let messages = try Vectors.load(MessagesFile.self, from: "messages.json")
        #expect(!messages.examples.isEmpty && !messages.streams.isEmpty)
        #expect(try !Vectors.load(StateSyncFile.self, from: "state-sync.json").cases.isEmpty)
        let l2cap = try Vectors.load(L2capFile.self, from: "l2cap.json")
        #expect(!l2cap.derivation.isEmpty && !l2cap.records.seals.isEmpty && !l2cap.records.failures.isEmpty)
    }

    @Test("the vendored vectors are byte for byte the launcher's, when a launcher checkout is beside this repo")
    func vendoredParity() throws {
        let local = try Self.vectors(in: Vectors.vendored)
        #expect(local.count >= 9)
        guard let launcher = Vectors.launcher else { return }
        let canonical = try Self.vectors(in: launcher.appending(path: "fixtures/bridge", directoryHint: .isDirectory))
        #expect(Set(local.keys) == Set(canonical.keys), "the vector sets differ; run tools/sync-vectors.sh")
        for (name, bytes) in canonical where local[name] != nil {
            #expect(local[name] == bytes, "fixtures/bridge/\(name) differs from the launcher's; run tools/sync-vectors.sh")
        }
    }

    // The launcher's directory also holds its README, which the copy here leaves out.
    private static func vectors(in directory: URL) throws -> [String: Data] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
        return try Dictionary(uniqueKeysWithValues: names.map { ($0, try Data(contentsOf: directory.appending(path: $0))) })
    }

    @Test("the spec header carries the same protocol version as the Swift constant", .enabled(if: Vectors.launcher != nil))
    func specParity() throws {
        let text = try Vectors.spec()
        let match = try #require(text.firstMatch(of: /bridgeProtocolVersion: (\d+)/))
        #expect(Int(match.1) == BridgeProtocol.version)
        let terms = [
            PairingCrypto.commitLabel, PairingCrypto.transcriptLabel, PairingCrypto.kBleLabel, PairingCrypto.sasLabel,
            PairingCrypto.confirmLabel, BridgeProtocol.bonjourType, "v=1", "pair=1", PairAbortReason.busy.rawValue,
            BridgeMessage.versionMismatch, BridgeMessage.replaced, L2capRecord.label,
        ].map { "`\($0)`" } + [PairingRole.phone, .mac].map { "UTF-8 \"\($0.rawValue)\"" }
        for term in terms {
            #expect(text.contains(term), "the spec does not name \(term)")
        }
    }
}

@Suite("chacha20poly1305.json")
struct ChaChaVectorTests {
    @Test(arguments: Vectors.chacha)
    func sealAndOpen(_ vector: ChaChaFile.Vector) throws {
        let key = SymmetricKey(data: Data(vectorHex: vector.key))
        let nonce = try ChaChaPoly.Nonce(data: Data(vectorHex: vector.nonce))
        let aad = Data(vectorHex: vector.aad)
        let box = try ChaChaPoly.seal(Data(vectorHex: vector.plaintext), using: key, nonce: nonce, authenticating: aad)
        #expect(box.ciphertext.hex == vector.ciphertext)
        #expect(box.tag.hex == vector.tag)
        let opened = try ChaChaPoly.open(
            ChaChaPoly.SealedBox(
                nonce: nonce, ciphertext: Data(vectorHex: vector.ciphertext), tag: Data(vectorHex: vector.tag)
            ),
            using: key, authenticating: aad
        )
        #expect(opened.hex == vector.plaintext)
    }
}

@Suite("x25519.json")
struct X25519VectorTests {
    private static func x25519(_ scalar: Data, _ u: Data) throws -> Data {
        let shared = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: scalar)
            .sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: u))
        return shared.withUnsafeBytes { Data($0) }
    }

    @Test(arguments: Vectors.x25519?.scalarMult ?? [])
    func scalarMultiplication(_ vector: X25519File.ScalarMult) throws {
        #expect(try Self.x25519(Data(vectorHex: vector.scalar), Data(vectorHex: vector.u)).hex == vector.output)
    }

    @Test(arguments: Vectors.x25519?.iterated ?? [])
    func iterated(_ vector: X25519File.Iterated) throws {
        var k = Data(vectorHex: vector.start)
        var u = k
        for _ in 0 ..< vector.iterations {
            (k, u) = (try Self.x25519(k, u), k)
        }
        #expect(k.hex == vector.output)
    }

    @Test(arguments: Vectors.x25519?.diffieHellman ?? [])
    func diffieHellman(_ vector: X25519File.DiffieHellman) throws {
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: vector.alicePrivate))
        let bob = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: vector.bobPrivate))
        #expect(alice.publicKey.rawRepresentation.hex == vector.alicePublic)
        #expect(bob.publicKey.rawRepresentation.hex == vector.bobPublic)
        let aliceShared = try PairingCrypto.sharedSecret(privateKey: alice, peerPublicKey: Data(vectorHex: vector.bobPublic))
        let bobShared = try PairingCrypto.sharedSecret(privateKey: bob, peerPublicKey: Data(vectorHex: vector.alicePublic))
        #expect(aliceShared.withUnsafeBytes { Data($0) }.hex == vector.shared)
        #expect(bobShared.withUnsafeBytes { Data($0) }.hex == vector.shared)
    }

    @Test("a low-order public key yields the all-zero secret and is refused")
    func allZeroSharedSecret() {
        #expect(throws: PairingCryptoError.zeroSharedSecret) {
            try PairingCrypto.sharedSecret(privateKey: .init(), peerPublicKey: Data(count: 32))
        }
    }

    @Test("a public key that is not 32 bytes is refused as malformed")
    func badPublicKey() {
        #expect(throws: PairingCryptoError.badPublicKey) {
            try PairingCrypto.sharedSecret(privateKey: .init(), peerPublicKey: Data(count: 31))
        }
    }
}

@Suite("hkdf.json")
struct HkdfVectorTests {
    @Test(arguments: Vectors.hkdf)
    func extractAndExpand(_ vector: HkdfFile.Vector) {
        let ikm = SymmetricKey(data: Data(vectorHex: vector.ikm))
        let salt = Data(vectorHex: vector.salt)
        let info = Data(vectorHex: vector.info)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: ikm, salt: salt)
        #expect(Data(prk).hex == vector.prk)
        let expanded = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: vector.length)
        #expect(expanded.withUnsafeBytes { Data($0) }.hex == vector.okm)
        let derived = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: vector.length)
        #expect(derived.withUnsafeBytes { Data($0) }.hex == vector.okm)
    }
}
