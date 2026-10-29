import CryptoKit
import Foundation
import Testing

private func reason(_ name: String) -> L2capRejection {
    switch name {
    case "authentication": .authentication
    case "malformed": .malformed
    default: preconditionFailure("unknown reason \(name)")
    }
}

private func bytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

private func privateKey(_ hex: String) throws -> Curve25519.KeyAgreement.PrivateKey {
    try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(vectorHex: hex))
}

// Feeds the stream in the given pieces and collects what the Mac's end makes of it.
private struct Fed {
    var replies: [Data] = []
    var authenticatedAt: [Int] = []
    var plaintext = Data()
    var failure: L2capRejection?
    var plaintextBeforeAuthentication = false
}

private func feed(_ channel: inout MacL2capChannel, _ stream: Data, pieces: [Int]) -> Fed {
    var fed = Fed()
    var offset = stream.startIndex
    var index = 0
    for size in pieces + [stream.count] {
        guard offset < stream.endIndex else { break }
        let end = min(offset + size, stream.endIndex)
        let input = channel.receive(stream[offset ..< end])
        if let reply = input.reply { fed.replies.append(reply) }
        if input.authenticated { fed.authenticatedAt.append(index) }
        if !input.plaintext.isEmpty, fed.authenticatedAt.isEmpty { fed.plaintextBeforeAuthentication = true }
        fed.plaintext.append(input.plaintext)
        if let failure = input.failure { fed.failure = failure }
        offset = end
        index += 1
    }
    return fed
}

private func decode(_ plaintext: Data) throws -> [BridgeMessage] {
    var decoder = TcpFrameDecoder()
    decoder.append(plaintext)
    var messages: [BridgeMessage] = []
    while let event = try decoder.next() {
        guard case .message(let message) = event else { continue }
        messages.append(message)
    }
    try decoder.finish()
    return messages
}

@Suite("l2cap.json")
struct L2capVectorTests {
    @Test("the label, sizes and timeout match the Swift constants")
    func constants() throws {
        let file = try #require(Vectors.l2cap)
        #expect(file.label == L2capRecord.label)
        #expect(file.handshakeKeyBytes == L2capRecord.handshakeKeyBytes)
        #expect(file.maxPlaintextBytes == L2capRecord.maxPlaintextBytes)
        #expect(file.minCiphertextBytes == L2capRecord.minCiphertextBytes)
        #expect(file.maxCiphertextBytes == L2capRecord.maxCiphertextBytes)
        #expect(Duration.milliseconds(file.timeoutMs) == LinkMachine.stepTimeout)
    }

    @Test(arguments: Vectors.l2cap?.derivation ?? [])
    func derivation(_ vector: L2capFile.Derivation) throws {
        let kBle = SymmetricKey(data: Data(vectorHex: vector.kBle))
        let phone = try privateKey(vector.phonePrivateKey)
        let pkPhone = Data(vectorHex: vector.phonePublicKey)
        let pkMac = Data(vectorHex: vector.macPublicKey)
        #expect(phone.publicKey.rawRepresentation == pkPhone)

        guard vector.expect == "keys" else {
            #expect(vector.expect == "zero-shared-secret")
            #expect(throws: PairingCryptoError.zeroSharedSecret) {
                try PairingCrypto.sharedSecret(privateKey: phone, peerPublicKey: pkMac)
            }
            // The Mac's end of the same exchange: the low-order key arrives as the phone's.
            var channel = MacL2capChannel(kBle: kBle)
            let input = channel.receive(pkMac)
            #expect(input.failure == .zeroSharedSecret && input.reply == nil)
            #expect(channel.phase == .failed(.zeroSharedSecret))
            return
        }
        let mac = try privateKey(try #require(vector.macPrivateKey))
        #expect(mac.publicKey.rawRepresentation == pkMac)
        let fromMac = try PairingCrypto.sharedSecret(privateKey: mac, peerPublicKey: pkPhone)
        let fromPhone = try PairingCrypto.sharedSecret(privateKey: phone, peerPublicKey: pkMac)
        #expect(bytes(fromMac).hex == vector.sharedSecret)
        #expect(bytes(fromPhone).hex == vector.sharedSecret)

        let salt = L2capRecord.salt(kBle: kBle, pkPhone: pkPhone, pkMac: pkMac)
        #expect(salt.hex == vector.salt)
        #expect(bytes(L2capRecord.okm(sharedSecret: fromMac, salt: salt)).hex == vector.okm)
        let keys = L2capRecord.keys(sharedSecret: fromMac, kBle: kBle, pkPhone: pkPhone, pkMac: pkMac)
        #expect(bytes(keys.phoneToMac).hex == vector.phoneToMacKey)
        #expect(bytes(keys.macToPhone).hex == vector.macToPhoneKey)

        // The Mac's end receives with the phone → Mac key and sends with the other one.
        var channel = MacL2capChannel(kBle: kBle, ephemeralKey: mac)
        let handshake = channel.receive(pkPhone)
        #expect(handshake.reply == pkMac)
        let record = try L2capRecord.seal(Data("ping".utf8), key: keys.phoneToMac, counter: 0)
        let opened = channel.receive(record)
        #expect(opened.authenticated && opened.plaintext == Data("ping".utf8) && opened.failure == nil)
        let sealed = try channel.seal(Data("pong".utf8))
        var reader = L2capRecordReader(key: keys.macToPhone)
        reader.append(sealed)
        let pong = try reader.next()
        #expect(pong == Data("pong".utf8))
    }

    @Test(arguments: Vectors.l2cap?.records.seals ?? [])
    func seal(_ vector: L2capFile.Seal) throws {
        let key = SymmetricKey(data: Data(vectorHex: vector.key))
        #expect(L2capRecord.nonce(counter: vector.counter).hex == vector.nonce)
        let plaintext: Data
        if let hex = vector.plaintext {
            plaintext = Data(vectorHex: hex)
        } else {
            #expect(vector.plaintextPattern == "i mod 256")
            let count = try #require(vector.plaintextBytes)
            plaintext = Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0) })
        }
        let record = try L2capRecord.seal(plaintext, key: key, counter: vector.counter)
        if let expected = vector.record {
            #expect(record.hex == expected)
        } else {
            #expect(record.count == vector.recordBytes)
            #expect(record.prefix(18).hex == vector.recordHead)
            #expect(record.suffix(16).hex == vector.tag)
            #expect(Data(SHA256.hash(data: record)).hex == vector.recordSha256)
        }
        var writer = L2capRecordWriter(key: key, counter: vector.counter)
        let written = try writer.seal(plaintext)
        #expect(written == record, "a plaintext that fits one record is sealed as one")
        var reader = L2capRecordReader(key: key, counter: vector.counter)
        reader.append(record)
        let opened = try reader.next()
        #expect(opened == plaintext)
        #expect(reader.counter == vector.counter + 1)
        try reader.finish()
    }

    @Test(arguments: Vectors.l2cap?.records.failures ?? [])
    func openFailure(_ vector: L2capFile.Failure) throws {
        #expect(vector.expect == "fail")
        var reader = L2capRecordReader(key: SymmetricKey(data: Data(vectorHex: vector.key)), counter: vector.counter)
        let head = Data(vectorHex: vector.stream)
        reader.append(head)
        if let zeroFill = vector.zeroFill {
            // Judged on the length alone, before the declared ciphertext is even in.
            #expect(throws: reason(vector.reason)) { _ = try reader.next() }
            reader.append(Data(count: zeroFill))
        }
        #expect(throws: reason(vector.reason)) {
            while try reader.next() != nil {}
            try reader.finish()
        }
    }

    @Test("the transcript through the Mac's handshake and record code, in pieces of every size")
    func transcript() throws {
        let vector = try #require(Vectors.l2cap).transcript
        let mac = try privateKey(vector.macPrivateKey)
        let kBle = SymmetricKey(data: Data(vectorHex: vector.kBle))
        let phoneStream = Data(vectorHex: vector.phoneStream)
        #expect(phoneStream == vector.phoneWrites.reduce(Data()) { $0 + Data(vectorHex: $1.bytes) })
        let phonePlaintext = vector.phoneWrites.dropFirst().reduce(Data()) { $0 + Data(vectorHex: $1.plaintext ?? "") }

        for pieces in [[phoneStream.count], [1], [31, 2, 43], [32, 44, 28, 40, 1000]] {
            var channel = MacL2capChannel(kBle: kBle, ephemeralKey: mac)
            let piecewise = pieces.count == 1 && pieces[0] < phoneStream.count
                ? Array(repeating: pieces[0], count: phoneStream.count) : pieces
            let fed = feed(&channel, phoneStream, pieces: piecewise)
            #expect(fed.replies == [Data(vectorHex: vector.macWrites[0].bytes)], "pieces \(pieces)")
            #expect(fed.authenticatedAt.count == 1 && !fed.plaintextBeforeAuthentication, "pieces \(pieces)")
            #expect(fed.failure == nil && fed.plaintext == phonePlaintext, "pieces \(pieces)")
            #expect(channel.phase == .open)
            try channel.finish()
        }

        var channel = MacL2capChannel(kBle: kBle, ephemeralKey: mac)
        #expect(channel.macPublicKey.hex == vector.macPublicKey)
        let fed = feed(&channel, phoneStream, pieces: [])
        #expect(try decode(fed.plaintext) == [
            .hello(version: BridgeProtocol.version), .activeSet(notifications: []), .bye(reason: nil),
        ])
        #expect(vector.phoneBodies.count == 3)

        // The Mac's own records: the frames its encoder writes, sealed from counter 0. JSONEncoder
        // does not keep member order from one process to the next, so the frames are compared by
        // content and the vector's bytes are what gets sealed.
        var macStream = channel.macPublicKey
        let frames = try [TcpFrame.encode(.hello(version: BridgeProtocol.version)), TcpFrame.encode(.syncRequest)]
        for (frame, write) in zip(frames, vector.macWrites.dropFirst()) {
            let plaintext = Data(vectorHex: write.plaintext ?? "")
            #expect(try decode(frame) == decode(plaintext))
            let sealed = try channel.seal(plaintext)
            #expect(sealed.hex == write.bytes, "\(write.what)")
            macStream += sealed
        }
        #expect(macStream.hex == vector.macStream)
        #expect(vector.macBodies.count == 2)
    }

    @Test("the transcript drives an L2CAP link to an established session and to bye, in pairing mode too")
    func transcriptSession() throws {
        let vector = try #require(Vectors.l2cap).transcript
        var channel = MacL2capChannel(kBle: SymmetricKey(data: Data(vectorHex: vector.kBle)), ephemeralKey: try privateKey(vector.macPrivateKey))
        let input = channel.receive(Data(vectorHex: vector.phoneStream))
        #expect(input.authenticated)
        var link = LinkMachine(transport: .l2cap)
        let open = LinkContext(isPinned: true, ceremony: .open, lastPairingModeExpired: false)
        var effects = link.connection(.ready(hasPeerCertificate: true))
        for message in try decode(input.plaintext) {
            effects += link.received(message, context: open)
        }
        #expect(effects == [
            .send(.hello(version: BridgeProtocol.version)), .armStepTimer, .startReceiving,
            .cancelStepTimer, .establishSession,
            .toSession(.activeSet(notifications: [])),
            .close(.bye),
        ])
    }
}
