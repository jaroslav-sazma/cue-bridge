import CryptoKit
import Foundation
import Testing

private let kBle = SymmetricKey(data: Data(repeating: 0x42, count: 32))
private let hello = BridgeMessage.hello(version: BridgeProtocol.version)

// The phone's end, built straight from the primitives: its key, then records under the key it derives.
private struct Phone {
    let key = Curve25519.KeyAgreement.PrivateKey()
    var publicKey: Data { key.publicKey.rawRepresentation }

    func writer(macKey: Data, kBle: SymmetricKey = kBle) throws -> L2capRecordWriter {
        L2capRecordWriter(key: try keys(macKey: macKey, kBle: kBle).phoneToMac)
    }

    func reader(macKey: Data) throws -> L2capRecordReader {
        L2capRecordReader(key: try keys(macKey: macKey, kBle: kBle).macToPhone)
    }

    private func keys(macKey: Data, kBle: SymmetricKey) throws -> L2capKeys {
        let shared = try PairingCrypto.sharedSecret(privateKey: key, peerPublicKey: macKey)
        return L2capRecord.keys(sharedSecret: shared, kBle: kBle, pkPhone: publicKey, pkMac: macKey)
    }
}

private func opened(_ phone: Phone) -> (MacL2capChannel, MacL2capChannel.Input) {
    var channel = MacL2capChannel(kBle: kBle)
    let input = channel.receive(phone.publicKey)
    return (channel, input)
}

private func messages(_ plaintext: Data) throws -> [BridgeMessage] {
    var decoder = TcpFrameDecoder()
    decoder.append(plaintext)
    var out: [BridgeMessage] = []
    while let event = try decoder.next() {
        if case .message(let message) = event { out.append(message) }
    }
    try decoder.finish()
    return out
}

@Suite("L2CAP handshake and records")
struct L2capChannelTests {
    @Test("the key comes in pieces; the answer goes out once it is whole, and only once")
    func handshakeInPieces() throws {
        let phone = Phone()
        var channel = MacL2capChannel(kBle: kBle)
        let first = channel.receive(phone.publicKey.prefix(20))
        #expect(first.reply == nil && channel.phase == .awaitingKey && !channel.isKeyed)
        let second = channel.receive(phone.publicKey.dropFirst(20))
        #expect(second.reply == channel.macPublicKey && channel.phase == .awaitingFirstRecord && channel.isKeyed)
        var writer = try phone.writer(macKey: channel.macPublicKey)
        let third = channel.receive(try writer.seal(TcpFrame.encode(hello)))
        #expect(third.reply == nil && third.authenticated && channel.phase == .open)
    }

    @Test("a handshake that stalls is ended by the step timer: an L2CAP link closes, it never sends pair-abort")
    func handshakeTimeout() {
        var channel = MacL2capChannel(kBle: kBle)
        _ = channel.receive(Phone().publicKey.prefix(31))
        #expect(channel.phase == .awaitingKey, "nothing but the timer ends a key that stops short")
        let link = LinkMachine(transport: .l2cap)
        #expect(link.stepExpired(armedIn: .handshaking, ceremonyPresent: true) == [.close(.stepTimeout(.handshaking))])
        var ready = LinkMachine(transport: .l2cap)
        _ = ready.connection(.ready(hasPeerCertificate: true))
        #expect(ready.stepExpired(armedIn: .awaitingHello, ceremonyPresent: true) == [.close(.stepTimeout(.awaitingHello))])
    }

    @Test("a stream that ends inside the key or inside a record is malformed; between them it is a plain end")
    func truncated() throws {
        var short = MacL2capChannel(kBle: kBle)
        _ = short.receive(Data(count: 31))
        #expect(throws: L2capRejection.malformed) { try short.finish() }
        #expect(throws: L2capRejection.malformed) { try MacL2capChannel(kBle: kBle).finish() }

        let phone = Phone()
        var (channel, handshake) = opened(phone)
        #expect(handshake.reply != nil)
        try channel.finish()
        #expect(channel.phase == .awaitingFirstRecord, "the central closed after the keys: no record, no session")

        var writer = try phone.writer(macKey: channel.macPublicKey)
        let record = try writer.seal(TcpFrame.encode(hello))
        let partial = channel.receive(record.dropLast(1))
        #expect(!partial.authenticated && partial.failure == nil)
        #expect(throws: L2capRejection.malformed) { try channel.finish() }
    }

    @Test("a phone with another K_ble fails on its first record and gets nothing past the key")
    func wrongKBle() throws {
        let phone = Phone()
        var (channel, handshake) = opened(phone)
        var writer = try phone.writer(macKey: handshake.reply ?? Data(), kBle: SymmetricKey(data: Data(repeating: 1, count: 32)))
        let input = channel.receive(try writer.seal(TcpFrame.encode(hello)))
        #expect(input.failure == .authentication && !input.authenticated && input.plaintext.isEmpty)
        #expect(channel.phase == .failed(.authentication))
        let after = channel.receive(try writer.seal(TcpFrame.encode(.bye(reason: nil))))
        #expect(after.plaintext.isEmpty && after.failure == nil && !after.authenticated, "a failed channel reads nothing more")
    }

    @Test("a low-order key (u = 0) is refused before anything is sent")
    func lowOrderKey() {
        var channel = MacL2capChannel(kBle: kBle)
        let input = channel.receive(Data(count: 32))
        #expect(input.failure == .zeroSharedSecret && input.reply == nil && !channel.isKeyed)
        #expect(throws: L2capSealError.notKeyed) { _ = try channel.seal(Data([1])) }
    }

    @Test("record boundaries mean nothing: a frame across three records, three frames in one record")
    func boundaries() throws {
        let phone = Phone()
        var (channel, handshake) = opened(phone)
        let macKey = try #require(handshake.reply)
        var writer = try phone.writer(macKey: macKey)
        let helloFrame = try TcpFrame.encode(hello)
        var stream = Data()
        for range in [0 ..< 3, 3 ..< 10, 10 ..< helloFrame.count] {
            stream += try writer.seal(helloFrame.subdata(in: range))
        }
        let info = NotificationInfo(
            key: "0|pkg|1|null|10001", pkg: "com.example", appLabel: "Example", title: "t", text: "x", when: 1,
            threadId: nil, canReply: false, isClearable: true, iconHash: nil
        )
        let three = try [
            TcpFrame.encode(.activeSet(notifications: [])), TcpFrame.encode(.notifDetail(info)),
            TcpFrame.encode(.bye(reason: "idle")),
        ].reduce(Data(), +)
        stream += try writer.seal(three)
        #expect(writer.counter == 4)

        var plaintext = Data()
        var authenticated = 0
        for offset in stride(from: 0, to: stream.count, by: 7) {
            let input = channel.receive(stream.subdata(in: offset ..< min(offset + 7, stream.count)))
            #expect(input.failure == nil)
            if input.authenticated { authenticated += 1 }
            plaintext += input.plaintext
        }
        #expect(authenticated == 1)
        #expect(try messages(plaintext) == [hello, .activeSet(notifications: []), .notifDetail(info), .bye(reason: "idle")])
    }

    @Test("a frame of over a megabyte goes out as full records and the rest, and comes back whole")
    func largeFrame() throws {
        let phone = Phone()
        var (channel, handshake) = opened(phone)
        let macKey = try #require(handshake.reply)
        let png = Data((0 ..< BridgeProtocol.maxBinaryBytes).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let frame = try TcpFrame.encode(.iconData(hash: IconHash.of(png), png: png))

        var phoneWriter = try phone.writer(macKey: macKey)
        let inbound = channel.receive(try phoneWriter.seal(frame))
        #expect(inbound.authenticated && inbound.failure == nil)
        #expect(try messages(inbound.plaintext) == [.iconData(hash: IconHash.of(png), png: png)])

        let sealed = try channel.seal(frame)
        let full = frame.count / L2capRecord.maxPlaintextBytes
        let records = full + (frame.count % L2capRecord.maxPlaintextBytes == 0 ? 0 : 1)
        #expect(sealed.count == frame.count + records * (L2capRecord.lengthBytes + L2capRecord.tagBytes))
        var reader = try phone.reader(macKey: macKey)
        reader.append(sealed)
        var back = Data()
        var lengths: [Int] = []
        while let plaintext = try reader.next() {
            back += plaintext
            lengths.append(plaintext.count)
        }
        try reader.finish()
        #expect(back == frame)
        #expect(lengths.count == records && lengths.dropLast().allSatisfy { $0 == L2capRecord.maxPlaintextBytes })
        #expect(reader.counter == UInt64(records))
    }

    @Test("a plaintext outside 1...16384 bytes is never sealed")
    func plaintextBounds() throws {
        let key = SymmetricKey(size: .bits256)
        #expect(throws: L2capSealError.plaintextSize(0)) { try L2capRecord.seal(Data(), key: key, counter: 0) }
        #expect(throws: L2capSealError.plaintextSize(16_385)) { try L2capRecord.seal(Data(count: 16_385), key: key, counter: 0) }
        var writer = L2capRecordWriter(key: key)
        let nothing = try writer.seal(Data())
        #expect(nothing.isEmpty && writer.counter == 0)
    }
}

@Suite("L2CAP session intake")
struct L2capIntakeTests {
    private let pinnedIdle = LinkContext(isPinned: true, ceremony: .none, lastPairingModeExpired: false)
    private let pinnedOpen = LinkContext(isPinned: true, ceremony: .open, lastPairingModeExpired: false)

    @Test("an L2CAP link is a session from its hello on, in pairing mode too")
    func sessionAfterHello() {
        for context in [pinnedIdle, pinnedOpen] {
            var link = LinkMachine(transport: .l2cap)
            _ = link.connection(.ready(hasPeerCertificate: true))
            #expect(link.received(hello, context: context) == [.cancelStepTimer, .establishSession])
            #expect(link.stage == .session)
        }
    }

    @Test("pair-request on L2CAP is a protocol error; a version mismatch gets bye as over TCP")
    func pairRequestRefused() {
        var link = LinkMachine(transport: .l2cap)
        _ = link.connection(.ready(hasPeerCertificate: true))
        _ = link.received(hello, context: pinnedOpen)
        #expect(link.received(.pairRequest(commit: "c"), context: pinnedOpen) == [.close(.protocolError(type: "pair-request"))])

        var other = LinkMachine(transport: .l2cap)
        _ = other.connection(.ready(hasPeerCertificate: true))
        #expect(other.received(.hello(version: 2), context: pinnedIdle) == [
            .cancelStepTimer, .send(.bye(reason: BridgeMessage.versionMismatch)), .close(.versionMismatch(peer: 2)),
        ])

        var unpinned = LinkMachine(transport: .l2cap)
        _ = unpinned.connection(.ready(hasPeerCertificate: true))
        let refused = unpinned.received(hello, context: LinkContext(isPinned: false, ceremony: .open, lastPairingModeExpired: false))
        #expect(refused == [.cancelStepTimer, .close(.unpinnedSession)], "never left waiting for a kind it cannot have")
    }

    // The server feeds `.ready` to an L2CAP link only for a channel whose first record opened, and only
    // `.establishSession` touches the slots: a failed handshake has neither.
    @Test("a failed handshake leaves the current session alone; a good one replaces it whatever its carrier")
    func failedHandshakeLeavesSession() throws {
        var slots = SessionSlots()
        slots.bindSession(1)

        let stranger = Phone()
        var (channel, handshake) = opened(stranger)
        var writer = try stranger.writer(macKey: try #require(handshake.reply), kBle: SymmetricKey(size: .bits256))
        let input = channel.receive(try writer.seal(TcpFrame.encode(hello)))
        #expect(!input.authenticated && input.failure == .authentication)
        let foreign = LinkMachine(transport: .l2cap)
        #expect(foreign.stage == .handshaking)
        #expect(foreign.stepExpired(armedIn: .handshaking, ceremonyPresent: false) == [.close(.stepTimeout(.handshaking))])
        let released = slots.detach(2)
        #expect(released == [] && slots.session == 1)

        let phone = Phone()
        var (good, keys) = opened(phone)
        var phoneWriter = try phone.writer(macKey: try #require(keys.reply))
        let accepted = good.receive(try phoneWriter.seal(TcpFrame.encode(hello)))
        #expect(accepted.authenticated)
        var link = LinkMachine(transport: .l2cap)
        _ = link.connection(.ready(hasPeerCertificate: true))
        var effects: [LinkEffect] = []
        for message in try messages(accepted.plaintext) {
            effects += link.received(message, context: pinnedIdle)
        }
        #expect(effects.contains(.establishSession))
        #expect(slots.superseded(by: 3) == 1)
    }

    @Test("a pending L2CAP link is not one a pair-request can close")
    func pairRequestSparesL2cap() {
        let links: [(id: Int, stage: LinkStage, isPinned: Bool)] = [(1, .awaitingKind, false), (2, .handshaking, true)]
        #expect(SessionSlots.closedByPairRequest(on: 1, links: links).isEmpty)
    }
}

private struct Peripheral {
    var machine = GattPeripheralMachine()
    var effects: [[GattPeripheralMachine.Effect]] = []

    mutating func on(_ step: (inout GattPeripheralMachine) -> [GattPeripheralMachine.Effect]) {
        effects.append(step(&machine))
    }

    var last: [GattPeripheralMachine.Effect] { effects.last ?? [] }

    static func paired(psm: UInt16) -> Peripheral {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.setPaired(true) }
        peripheral.on { $0.radio(.poweredOn) }
        peripheral.on { $0.channelPublished(psm: psm, error: nil) }
        peripheral.on { $0.serviceAdded(error: nil) }
        peripheral.on { $0.advertisingStarted(error: nil) }
        return peripheral
    }
}

@Suite("L2CAP channel publishing")
struct L2capPublishingTests {
    @Test("paired: the channel is published first, the service carries its PSM, then advertising starts")
    func pairedLifecycle() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.setPaired(true) }
        #expect(peripheral.last.isEmpty, "the radio is not on yet")
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.publishChannel])
        #expect(peripheral.machine.channel == .publishing && peripheral.machine.service == .idle)
        peripheral.on { $0.channelPublished(psm: 0x0081, error: nil) }
        #expect(peripheral.last == [.addService(psm: 0x0081)])
        peripheral.on { $0.serviceAdded(error: nil) }
        #expect(peripheral.last == [.startAdvertising])
        #expect(peripheral.machine.channel == .published(psm: 0x0081) && peripheral.machine.servicePsm == 0x0081)
        peripheral.on { $0.disable() }
        #expect(peripheral.last == [.unpublishChannel(0x0081), .teardown])
    }

    @Test("pairing mode without a pairing has no channel and no psm characteristic")
    func pairingMode() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.setPaired(false) }
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.addService(psm: nil)])
        #expect(peripheral.machine.channel == .idle)
    }

    @Test("a pairing that commits publishes and adds the service again with the PSM, which ends subscriptions")
    func commit() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.radio(.poweredOn) }
        peripheral.on { $0.serviceAdded(error: nil) }
        peripheral.on { $0.advertisingStarted(error: nil) }
        peripheral.machine.subscribed(UUID(), payload: 244)
        peripheral.on { $0.setPaired(true) }
        #expect(peripheral.last == [.publishChannel])
        #expect(peripheral.machine.subscribed, "the old service stays until the PSM is there")
        peripheral.on { $0.channelPublished(psm: 0x0085, error: nil) }
        #expect(peripheral.last == [.addService(psm: 0x0085)])
        #expect(!peripheral.machine.subscribed)
        peripheral.on { $0.serviceAdded(error: nil) }
        #expect(peripheral.last.isEmpty, "advertising goes on")
        #expect(peripheral.machine.isAdvertising)
    }

    @Test("only a service added again over one in the database counts as the Mac ending the subscriptions")
    func readdCounted() {
        var peripheral = Peripheral.paired(psm: 0x0081)
        #expect(peripheral.machine.serviceReadds == 0, "the first add")
        peripheral.on { $0.radio(.poweredOff) }
        peripheral.on { $0.radio(.poweredOn) }
        peripheral.on { $0.channelPublished(psm: 0x0083, error: nil) }
        peripheral.on { $0.serviceAdded(error: nil) }
        #expect(peripheral.machine.serviceReadds == 0, "a power cycle is the radio's, not a re-add")
        peripheral.machine.subscribed(UUID(), payload: 244)
        peripheral.on { $0.setPaired(false) }
        #expect(peripheral.last == [.unpublishChannel(0x0083), .addService(psm: nil)])
        #expect(!peripheral.machine.subscribed && peripheral.machine.serviceReadds == 1)
    }

    @Test("unpairing while pairing mode keeps the service up unpublishes the channel and drops the psm characteristic")
    func unpairDuringCeremony() {
        var peripheral = Peripheral.paired(psm: 0x0081)
        peripheral.on { $0.setPaired(false) }
        #expect(peripheral.last == [.unpublishChannel(0x0081), .addService(psm: nil)])
        #expect(peripheral.machine.channel == .idle)
    }

    @Test("after a power cycle the old PSM is released, the channel published again and the service carries the new PSM")
    func powerCycle() {
        var peripheral = Peripheral.paired(psm: 0x0081)
        peripheral.on { $0.radio(.poweredOff) }
        #expect(peripheral.last.isEmpty)
        #expect(peripheral.machine.channel == .idle && peripheral.machine.servicePsm == nil)
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.unpublishChannel(0x0081), .publishChannel])
        peripheral.on { $0.channelPublished(psm: 0x0083, error: nil) }
        #expect(peripheral.last == [.addService(psm: 0x0083)])
    }

    @Test("a failed publish leaves the service without psm until the next power cycle")
    func publishFailure() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.setPaired(true) }
        peripheral.on { $0.radio(.poweredOn) }
        peripheral.on { $0.channelPublished(psm: 0, error: "no resources") }
        #expect(peripheral.last == [.addService(psm: nil)])
        #expect(peripheral.machine.channel == .failed("no resources"))
        peripheral.on { $0.radio(.poweredOff) }
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.publishChannel])
    }

    @Test("a publish that answers after the unpairing is released; one answering nobody is ignored")
    func latePublish() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.setPaired(true) }
        peripheral.on { $0.radio(.poweredOn) }
        peripheral.on { $0.setPaired(false) }
        #expect(peripheral.last == [.addService(psm: nil)])
        peripheral.on { $0.channelPublished(psm: 0x0081, error: nil) }
        #expect(peripheral.last == [.unpublishChannel(0x0081)])
        peripheral.on { $0.channelPublished(psm: 0x0087, error: nil) }
        #expect(peripheral.last.isEmpty)
    }

    @Test("the service waits for a PSM published while it was being added, then is added again with it")
    func publishDuringAdd() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.addService(psm: nil)])
        peripheral.on { $0.setPaired(true) }
        #expect(peripheral.last == [.publishChannel])
        peripheral.on { $0.channelPublished(psm: 0x0081, error: nil) }
        #expect(peripheral.last.isEmpty, "the first add is still under way")
        peripheral.on { $0.serviceAdded(error: nil) }
        #expect(peripheral.last == [.addService(psm: 0x0081)])
        peripheral.on { $0.serviceAdded(error: nil) }
        #expect(peripheral.last == [.startAdvertising])
    }
}
