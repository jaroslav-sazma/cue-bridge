import CryptoKit
import Foundation

nonisolated enum L2capRejection: Error, Equatable, Sendable {
    case malformed
    case authentication
    case zeroSharedSecret
}

nonisolated enum L2capSealError: Error, Equatable {
    case plaintextSize(Int)
    case notKeyed
}

nonisolated struct L2capKeys: Sendable {
    var phoneToMac: SymmetricKey
    var macToPhone: SymmetricKey
}

nonisolated enum L2capRecord {
    static let label = "app.cue.bridge/l2cap/v1"
    static let handshakeKeyBytes = 32
    static let lengthBytes = 2
    static let tagBytes = 16
    static let maxPlaintextBytes = 16_384
    static let minCiphertextBytes = 1 + tagBytes
    static let maxCiphertextBytes = maxPlaintextBytes + tagBytes

    // K_ble goes into the hash straight from its key storage, so no copy of it outlives the call.
    static func salt(kBle: SymmetricKey, pkPhone: Data, pkMac: Data) -> Data {
        var hash = SHA256()
        kBle.withUnsafeBytes { bytes in
            var length = Data()
            length.appendUInt16(UInt16(bytes.count))
            hash.update(data: length)
            hash.update(bufferPointer: bytes)
        }
        for part in [pkPhone, pkMac] {
            var length = Data()
            length.appendUInt16(UInt16(part.count))
            hash.update(data: length)
            hash.update(data: part)
        }
        return Data(hash.finalize())
    }

    static func okm(sharedSecret: SymmetricKey, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: sharedSecret, salt: salt, info: Data(label.utf8), outputByteCount: 64
        )
    }

    static func keys(sharedSecret: SymmetricKey, kBle: SymmetricKey, pkPhone: Data, pkMac: Data) -> L2capKeys {
        let okm = okm(sharedSecret: sharedSecret, salt: salt(kBle: kBle, pkPhone: pkPhone, pkMac: pkMac))
        return okm.withUnsafeBytes { bytes in
            L2capKeys(
                phoneToMac: SymmetricKey(data: UnsafeRawBufferPointer(rebasing: bytes[..<32])),
                macToPhone: SymmetricKey(data: UnsafeRawBufferPointer(rebasing: bytes[32...]))
            )
        }
    }

    static func nonce(counter: UInt64) -> Data {
        var nonce = Data(capacity: 12)
        nonce.appendUInt32(0)
        nonce.appendUInt64(counter)
        return nonce
    }

    static func seal(_ plaintext: Data, key: SymmetricKey, counter: UInt64) throws -> Data {
        guard (1...maxPlaintextBytes).contains(plaintext.count) else {
            throw L2capSealError.plaintextSize(plaintext.count)
        }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce(counter: counter)))
        var record = Data(capacity: lengthBytes + plaintext.count + tagBytes)
        record.appendUInt16(UInt16(plaintext.count + tagBytes))
        record.append(box.ciphertext)
        record.append(box.tag)
        return record
    }
}

// One direction's incoming records. The length is judged as soon as both of its bytes are in, so an
// out-of-range record fails as malformed before any AEAD. After a throw the stream is dead.
nonisolated struct L2capRecordReader {
    private let key: SymmetricKey
    private(set) var counter: UInt64
    private var buffer = Data()

    init(key: SymmetricKey, counter: UInt64 = 0) {
        self.key = key
        self.counter = counter
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() throws(L2capRejection) -> Data? {
        guard buffer.count >= L2capRecord.lengthBytes else { return nil }
        let length = Int(buffer.uint16(at: 0))
        guard (L2capRecord.minCiphertextBytes...L2capRecord.maxCiphertextBytes).contains(length) else {
            throw .malformed
        }
        guard buffer.count >= L2capRecord.lengthBytes + length else { return nil }
        let start = buffer.startIndex + L2capRecord.lengthBytes
        let tagStart = start + length - L2capRecord.tagBytes
        let plaintext: Data
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: L2capRecord.nonce(counter: counter)),
                ciphertext: buffer[start ..< tagStart], tag: buffer[tagStart ..< start + length]
            )
            plaintext = try ChaChaPoly.open(box, using: key)
        } catch {
            throw .authentication
        }
        buffer.removeSubrange(buffer.startIndex ..< start + length)
        counter += 1
        return plaintext
    }

    // The peer closed: between records that is a normal end, inside one it is fatal.
    func finish() throws(L2capRejection) {
        guard buffer.isEmpty else { throw .malformed }
    }
}

// One direction's outgoing records. A record boundary has no meaning to the reader, so a write of
// more than one record's plaintext goes out as full records and the rest.
nonisolated struct L2capRecordWriter {
    private let key: SymmetricKey
    private(set) var counter: UInt64

    init(key: SymmetricKey, counter: UInt64 = 0) {
        self.key = key
        self.counter = counter
    }

    mutating func seal(_ bytes: Data) throws -> Data {
        let recordCount = (bytes.count + L2capRecord.maxPlaintextBytes - 1) / L2capRecord.maxPlaintextBytes
        var out = Data(capacity: bytes.count + recordCount * (L2capRecord.lengthBytes + L2capRecord.tagBytes))
        var offset = bytes.startIndex
        while offset < bytes.endIndex {
            let end = min(offset + L2capRecord.maxPlaintextBytes, bytes.endIndex)
            out.append(try L2capRecord.seal(Data(bytes[offset ..< end]), key: key, counter: counter))
            counter += 1
            offset = end
        }
        return out
    }
}

// The Mac's end of one L2CAP channel as a pure machine: the caller feeds what arrives and writes what
// comes back. The phone speaks first with its ephemeral key; the Mac answers with its own, and the
// first record that opens under the phone → Mac key is what authenticates the phone — before it the
// channel carried nothing but public keys. The ephemeral private key and K_ble are dropped as soon
// as the record keys exist; the shared secret never leaves the derivation.
nonisolated struct MacL2capChannel {
    enum Phase: Equatable, Sendable {
        case awaitingKey
        case awaitingFirstRecord
        case open
        case failed(L2capRejection)
    }

    // `plaintext` is what opened before a failure, if one ended the input: it is still the peer's.
    struct Input {
        var reply: Data?
        var authenticated = false
        var plaintext = Data()
        var failure: L2capRejection?
    }

    let macPublicKey: Data
    private(set) var phase = Phase.awaitingKey
    private var ephemeralKey: Curve25519.KeyAgreement.PrivateKey?
    private var kBle: SymmetricKey?
    private var phoneKey = Data()
    private var reader: L2capRecordReader?
    private var writer: L2capRecordWriter?

    init(kBle: SymmetricKey, ephemeralKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.kBle = kBle
        self.ephemeralKey = ephemeralKey
        macPublicKey = ephemeralKey.publicKey.rawRepresentation
    }

    var isKeyed: Bool { writer != nil }

    mutating func receive(_ bytes: Data) -> Input {
        var input = Input()
        var rest = bytes[...]
        switch phase {
        case .failed:
            return input
        case .awaitingKey:
            let take = min(L2capRecord.handshakeKeyBytes - phoneKey.count, rest.count)
            phoneKey.append(rest.prefix(take))
            rest = rest.dropFirst(take)
            guard phoneKey.count == L2capRecord.handshakeKeyBytes else { return input }
            do {
                try derive()
            } catch {
                phase = .failed(error)
                input.failure = error
                return input
            }
            input.reply = macPublicKey
            phase = .awaitingFirstRecord
        case .awaitingFirstRecord, .open:
            break
        }
        guard var reader else { return input }
        reader.append(Data(rest))
        do {
            while let plaintext = try reader.next() {
                if phase == .awaitingFirstRecord {
                    phase = .open
                    input.authenticated = true
                }
                input.plaintext.append(plaintext)
            }
        } catch {
            phase = .failed(error)
            input.failure = error
        }
        self.reader = reader
        return input
    }

    // The peer closed its side. Inside the handshake or inside a record that is fatal.
    func finish() throws(L2capRejection) {
        switch phase {
        case .awaitingKey:
            throw .malformed
        case .awaitingFirstRecord, .open:
            try reader?.finish()
        case .failed:
            break
        }
    }

    mutating func seal(_ bytes: Data) throws -> Data {
        guard var writer else { throw L2capSealError.notKeyed }
        defer { self.writer = writer }
        return try writer.seal(bytes)
    }

    private mutating func derive() throws(L2capRejection) {
        defer {
            ephemeralKey = nil
            kBle = nil
        }
        guard let ephemeralKey, let kBle else { throw .malformed }
        let shared: SymmetricKey
        do {
            shared = try PairingCrypto.sharedSecret(privateKey: ephemeralKey, peerPublicKey: phoneKey)
        } catch {
            throw error == .zeroSharedSecret ? .zeroSharedSecret : .malformed
        }
        let keys = L2capRecord.keys(sharedSecret: shared, kBle: kBle, pkPhone: phoneKey, pkMac: macPublicKey)
        reader = L2capRecordReader(key: keys.phoneToMac)
        writer = L2capRecordWriter(key: keys.macToPhone)
    }
}
