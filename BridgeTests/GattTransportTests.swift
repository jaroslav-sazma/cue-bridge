import CryptoKit
import Foundation
import Testing

private let key = SymmetricKey(data: Data(repeating: 7, count: 32))
private let hash = "54892d1f759b11f6"

private func phoneFrame(_ signal: Signal, seq: UInt32, key: SymmetricKey = key) throws -> Data {
    try SignalFrame.seal(type: signal.code, seq: seq, plaintext: signal.plaintext(), key: key, direction: .phoneToMac)
}

@Suite("GATT transport")
struct GattTransportTests {
    @Test("the service and characteristic UUIDs match the spec's GATT transport table", .enabled(if: Vectors.launcher != nil))
    func uuidsMatchSpec() throws {
        let text = try Vectors.spec()
        let rows = [
            ("Service", BridgeProtocol.gattService),
            ("`doorbell` characteristic", BridgeProtocol.gattDoorbell),
            ("`command` characteristic", BridgeProtocol.gattCommand),
            ("`psm` characteristic", BridgeProtocol.gattPsm),
        ]
        for (element, uuid) in rows {
            #expect(text.contains("| \(element) | `\(uuid)` |"), "the spec's GATT table does not give \(element) as \(uuid)")
        }
        #expect(Set(rows.map(\.1)).count == 4)
    }

    @Test("a frame goes to the confirmed phone over GATT when it fits, else over the session, else nowhere; only a summon reaches an unconfirmed subscriber")
    func carrier() {
        let confirmed = SignalPaths(phonePayload: 244, summonPayload: 244, sessionUp: true)
        #expect(confirmed.carrier(frameBytes: 180) == .gatt)
        let smallMtu = SignalPaths(phonePayload: 182, summonPayload: 182, sessionUp: true)
        #expect(smallMtu.carrier(frameBytes: 183) == .tcp)
        #expect(smallMtu.carrier(frameBytes: 182) == .gatt)
        #expect(SignalPaths(phonePayload: 182, summonPayload: 182, sessionUp: false).carrier(frameBytes: 183) == nil)
        let stranger = SignalPaths(summonPayload: 244, sessionUp: false)
        #expect(stranger.carrier(frameBytes: 21, audience: .anyone) == .gatt,
                "with no session an unconfirmed subscriber is the only way a summon gets out")
        #expect(stranger.carrier(frameBytes: 21, audience: .phone) == nil, "nothing else goes to it")
        #expect(SignalPaths(sessionUp: true).carrier(frameBytes: 21) == .tcp)
        #expect(SignalPaths(sessionUp: false).carrier(frameBytes: 21, audience: .anyone) == nil)
        #expect(SignalPaths.frameBytes(plaintextBytes: SignalFrame.maxPlaintextBytes) == SignalFrame.maxFrameBytes)
    }

    @Test("dismiss, reply and clip frames never go to a subscriber that is not confirmed; a summon may")
    func userActionsNeedTheConfirmedPhone() throws {
        let stranger = SignalPaths(summonPayload: 244, sessionUp: false)
        let actions: [Signal] = [
            .dismiss(keyHash: hash), .reply(keyHash: hash, text: "ok"), .replyOverTcp(keyHash: hash),
            .clipboardSmall(text: "x", sensitive: false), .clipboardPending, .ping,
        ]
        for signal in actions {
            #expect(signal.audience == .phone, "\(signal.name)")
            #expect(try stranger.carrier(for: signal) == nil, "\(signal.name)")
        }
        #expect(Signal.syncRequest.audience == .anyone)
        #expect(try stranger.carrier(for: .syncRequest) == .gatt)
        let long = try ReplyEncoding.plan(key: "0|a|1|null|2", text: String(repeating: "y", count: 300))
        #expect(try stranger.plan(long) == nil, "not even the tcp flag")
        #expect(try stranger.plan(ClipboardEncoding.plan("short")) == nil)
    }

    @Test("with a session up an unconfirmed subscriber never takes a frame, a summon included")
    func sessionBeatsUnconfirmedSubscriber() throws {
        let paths = SignalPaths(summonPayload: 244, sessionUp: true)
        #expect(paths.carrier(frameBytes: 20, audience: .anyone) == .tcp)
        for signal in [Signal.dismiss(keyHash: hash), .syncRequest, .replyOverTcp(keyHash: hash)] {
            #expect(try paths.carrier(for: signal) == .tcp, "\(signal.name)")
        }
        let short = try ReplyEncoding.plan(key: "0|a|1|null|2", text: "ok")
        guard case .inline(let inline) = short else {
            Issue.record("a short reply is inline")
            return
        }
        #expect(try paths.plan(short) == [.signal(inline, .tcp)])
    }

    @Test("every signal the Mac sends today fits a 185-byte MTU's payload")
    func signalsFitGatt() throws {
        let paths = SignalPaths(phonePayload: GattPeripheralMachine.minimumPayload, sessionUp: false)
        #expect(GattPeripheralMachine.minimumPayload == 185 - 3)
        let longest = String(repeating: "x", count: 100)
        for signal in [Signal.dismiss(keyHash: hash), .syncRequest, .replyOverTcp(keyHash: hash), .ping] {
            #expect(try paths.carrier(for: signal) == .gatt, "\(signal.name)")
        }
        if case .inline(let reply) = try ReplyEncoding.plan(key: "k", text: longest) {
            #expect(try paths.carrier(for: reply) == .gatt)
        } else {
            Issue.record("a 100-byte reply is inline")
        }
    }

    @Test("a reply too long for a frame: with a session the text follows on it, without one it waits")
    func replyPlans() throws {
        let long = try ReplyEncoding.plan(key: "0|a|1|null|2", text: String(repeating: "y", count: 300))
        guard case .overTcp(let flag, let message) = long else {
            Issue.record("300 bytes do not fit inline")
            return
        }
        #expect(try SignalPaths(sessionUp: true).plan(long) == [.signal(flag, .tcp), .message(message)])
        #expect(
            try SignalPaths(phonePayload: 244, summonPayload: 244, sessionUp: true).plan(long)
                == [.signal(flag, .gatt), .message(message)]
        )
        #expect(try SignalPaths(summonPayload: 244, sessionUp: true).plan(long) == [.signal(flag, .tcp), .message(message)])
        #expect(
            try SignalPaths(phonePayload: 244, summonPayload: 244, sessionUp: false).plan(long)
                == [.signal(flag, .gatt), .keepForNextSession(message)]
        )
        #expect(try SignalPaths(sessionUp: false).plan(long) == nil, "nothing leaves: the loud failure")
        let short = try ReplyEncoding.plan(key: "0|a|1|null|2", text: "ok")
        guard case .inline(let inline) = short else {
            Issue.record("a short reply is inline")
            return
        }
        #expect(try SignalPaths(phonePayload: 244, sessionUp: false).plan(short) == [.signal(inline, .gatt)])
    }

    @Test("one intake: a frame is accepted once whichever carrier brings it, and a drop changes nothing")
    func intake() throws {
        var window = ReplayWindow()
        let posted = try phoneFrame(.notifPosted(keyHash: hash), seq: 4)
        let first = SignalIntake.take(posted, key: key, window: &window)
        guard case .accepted(let opened, let interpretation) = first else {
            Issue.record("the first copy is accepted")
            return
        }
        #expect(opened.seq == 4 && window.highest == 4)
        #expect(interpretation == .valid(.notifPosted(keyHash: hash)))
        #expect(SignalIntake.take(posted, key: key, window: &window) == .dropped(.replay), "the copy over the other carrier")
        let foreign = try phoneFrame(.notifPosted(keyHash: hash), seq: 9, key: SymmetricKey(data: Data(repeating: 1, count: 32)))
        #expect(SignalIntake.take(foreign, key: key, window: &window) == .dropped(.authentication))
        #expect(SignalIntake.take(Data(count: 20), key: key, window: &window) == .dropped(.malformed))
        #expect(window == .accepting([4]))
        let macFrame = try SignalFrame.seal(type: 3, seq: 5, plaintext: Data(#"{"k":"\#(hash)"}"#.utf8), key: key, direction: .macToPhone)
        #expect(SignalIntake.take(macFrame, key: key, window: &window) == .dropped(.authentication), "never its own direction")
        let gap = SignalIntake.take(try phoneFrame(.replyError(keyHash: hash, reason: nil), seq: 10), key: key, window: &window)
        #expect(gap != .dropped(.replay) && window.highest == 10, "gaps are allowed")
        let overtaken = SignalIntake.take(try phoneFrame(.notifRemoved(keyHash: hash), seq: 7), key: key, window: &window)
        #expect(overtaken != .dropped(.replay), "a seq inside the window not seen yet, from the slower carrier")
        #expect(SignalIntake.take(try phoneFrame(.notifRemoved(keyHash: hash), seq: 7), key: key, window: &window) == .dropped(.replay))
    }

    @Test("an accepted frame of an unknown type still uses up its seq")
    func unknownTypeAdvances() throws {
        var window = ReplayWindow.accepting([1])
        let frame = try SignalFrame.seal(type: 99, seq: 2, plaintext: Data("{}".utf8), key: key, direction: .phoneToMac)
        #expect(SignalIntake.take(frame, key: key, window: &window) != .dropped(.replay))
        #expect(window.highest == 2)
        #expect(SignalIntake.take(frame, key: key, window: &window) == .dropped(.replay))
    }

    @Test("waiting reply texts go out once, in order, and are forgotten on demand")
    func pendingReplyTexts() {
        var pending = PendingReplyTexts()
        pending.keep(.replyText(key: "a", text: "1"))
        pending.keep(.replyText(key: "b", text: "2"))
        #expect(pending.count == 2)
        let taken = pending.takeAll()
        #expect(taken == [.replyText(key: "a", text: "1"), .replyText(key: "b", text: "2")])
        #expect(pending.takeAll().isEmpty, "sent once")
        for index in 0..<PendingReplyTexts.capacity {
            pending.keep(.replyText(key: "k\(index)", text: "t"))
        }
        let dropped = pending.keep(.replyText(key: "last", text: "t"))
        #expect(dropped == 1 && pending.count == PendingReplyTexts.capacity)
        #expect(pending.messages.first == .replyText(key: "k1", text: "t"))
        pending.forgetAll()
        #expect(pending.count == 0)
    }

    @Test("a reply text that waited past its answer's deadline is dropped, not sent late")
    func overdueReplyText() {
        let start = ContinuousClock.now
        var pending = PendingReplyTexts()
        pending.keep(.replyText(key: "old", text: "1"), at: start)
        pending.keep(.replyText(key: "new", text: "2"), at: start + .seconds(20))
        let taken = pending.takeAll(at: start + PendingReplies.answerDeadline)
        #expect(taken == [.replyText(key: "new", text: "2")])
        #expect(pending.count == 0)
    }
}

// #expect cannot take a mutating call, so each step records what it returned.
private struct Peripheral {
    var machine = GattPeripheralMachine()
    var effects: [[GattPeripheralMachine.Effect]] = []

    mutating func on(_ step: (inout GattPeripheralMachine) -> [GattPeripheralMachine.Effect]) {
        effects.append(step(&machine))
    }

    var last: [GattPeripheralMachine.Effect] { effects.last ?? [] }
}

@Suite("GATT peripheral")
struct GattPeripheralTests {
    @Test("enable creates the manager; power on adds the service, then advertising starts")
    func lifecycle() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        #expect(peripheral.last == [.createManager])
        peripheral.on { $0.enable() }
        #expect(peripheral.last.isEmpty)
        peripheral.on { $0.radio(.unknown) }
        #expect(peripheral.last.isEmpty)
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.addService(psm: nil)])
        peripheral.on { $0.serviceAdded(error: nil) }
        #expect(peripheral.last == [.startAdvertising])
        peripheral.on { $0.advertisingStarted(error: nil) }
        #expect(peripheral.machine.isAdvertising)
        peripheral.on { $0.disable() }
        #expect(peripheral.last == [.teardown])
        #expect(peripheral.machine == GattPeripheralMachine())
        peripheral.on { $0.enable() }
        #expect(peripheral.last == [.createManager], "a new manager after a teardown")
    }

    @Test("powered off clears the service, advertising and subscriptions; powered on adds the service again")
    func powerCycle() {
        var peripheral = Peripheral()
        peripheral.on { $0.enable() }
        peripheral.on { $0.radio(.poweredOn) }
        peripheral.on { $0.serviceAdded(error: nil) }
        peripheral.on { $0.advertisingStarted(error: nil) }
        peripheral.machine.subscribed(UUID(), payload: 244)
        #expect(peripheral.machine.enqueue(Data(count: 40), to: .anyone) == 0)
        peripheral.on { $0.radio(.poweredOff) }
        #expect(peripheral.last.isEmpty)
        #expect(!peripheral.machine.isAdvertising && !peripheral.machine.subscribed && peripheral.machine.pending.isEmpty)
        #expect(peripheral.machine.service == .idle)
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.addService(psm: nil)])
        peripheral.on { $0.serviceAdded(error: nil) }
        #expect(peripheral.last == [.startAdvertising])
    }

    @Test("a failed service or advertising start stays failed until the next power cycle; disabled ignores callbacks")
    func failures() {
        var peripheral = Peripheral()
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last.isEmpty, "not enabled")
        peripheral.on { $0.enable() }
        peripheral.on { $0.radio(.poweredOn) }
        peripheral.on { $0.serviceAdded(error: "busy") }
        #expect(peripheral.last.isEmpty)
        #expect(peripheral.machine.service == .failed("busy"))
        peripheral.on { $0.radio(.resetting) }
        peripheral.on { $0.radio(.poweredOn) }
        #expect(peripheral.last == [.addService(psm: nil)])
        peripheral.on { $0.serviceAdded(error: nil) }
        peripheral.on { $0.advertisingStarted(error: "no slot") }
        #expect(peripheral.machine.advertising == .failed("no slot") && !peripheral.machine.isAdvertising)
    }

    @Test("a summon is sized for every subscriber while none is confirmed; the last unsubscribe drops what waits")
    func subscriptions() {
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        let other = UUID()
        #expect(machine.payload(for: .anyone) == nil && machine.enqueue(Data(count: 10), to: .anyone) == nil)
        machine.subscribed(phone, payload: 244)
        machine.subscribed(other, payload: 200)
        #expect(machine.payload(for: .anyone) == 200 && machine.payload(for: .phone) == nil)
        #expect(machine.enqueue(Data(count: 201), to: .anyone) == nil, "does not fit every central")
        #expect(machine.enqueue(Data(count: 30), to: .phone) == nil, "no confirmed phone to take it")
        #expect(machine.enqueue(Data(count: 200), to: .anyone) == 0)
        #expect(machine.pending.first?.recipients == [phone, other], "with none confirmed every subscriber gets a summon")
        machine.unsubscribed(other)
        #expect(machine.payload(for: .anyone) == 244 && machine.pending.count == 1)
        machine.unsubscribed(phone)
        #expect(!machine.subscribed && machine.pending.isEmpty)
    }

    @Test("a bare subscription is not the phone; an accepted ping from the subscriber confirms it")
    func pingConfirms() throws {
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        machine.subscribed(phone, payload: 182)
        #expect(machine.subscribed && machine.payload(for: .anyone) == 182)
        #expect(!machine.phoneLinked, "subscribing proves nothing")
        var window = ReplayWindow()
        let ping = SignalIntake.take(try phoneFrame(.ping, seq: 0), key: key, window: &window)
        #expect(ping == .accepted(OpenedSignal(type: 9, seq: 0, plaintext: Data("{}".utf8)), .valid(.ping)))
        let confirmed = machine.received(ping, from: phone)
        #expect(confirmed && machine.phoneLinked && machine.payload(for: .phone) == 182)
        let again = machine.received(ping, from: phone)
        #expect(!again && machine.phoneLinked, "already confirmed")
    }

    @Test("any accepted frame confirms its writer, even one whose type is ignored; only a subscribed writer counts")
    func anyAcceptedFrameConfirms() throws {
        var window = ReplayWindow()
        let posted = SignalIntake.take(try phoneFrame(.notifPosted(keyHash: hash), seq: 1), key: key, window: &window)
        let unknown = SignalIntake.take(
            try SignalFrame.seal(type: 99, seq: 2, plaintext: Data("{}".utf8), key: key, direction: .phoneToMac),
            key: key, window: &window
        )
        for intake in [posted, unknown] {
            var machine = GattPeripheralMachine()
            _ = machine.enable()
            let phone = UUID()
            let stranger = UUID()
            let fromOutsider = machine.received(intake, from: stranger)
            #expect(!fromOutsider && !machine.phoneLinked, "a writer that is not subscribed confirms nothing")
            machine.subscribed(phone, payload: 182)
            let fromPhone = machine.received(intake, from: phone)
            #expect(fromPhone && machine.phoneLinked)
        }
    }

    @Test("a replayed, foreign or garbage write never confirms")
    func droppedWritesNeverConfirm() throws {
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let central = UUID()
        machine.subscribed(central, payload: 182)
        var window = ReplayWindow.accepting([5])
        let replayed = SignalIntake.take(try phoneFrame(.ping, seq: 5), key: key, window: &window)
        let foreign = SignalIntake.take(
            try phoneFrame(.ping, seq: 6, key: SymmetricKey(data: Data(repeating: 1, count: 32))), key: key, window: &window
        )
        let garbage = SignalIntake.take(Data(repeating: 0xAB, count: 30), key: key, window: &window)
        let tooShort = SignalIntake.take(Data([9]), key: key, window: &window)
        #expect([replayed, foreign, garbage, tooShort].allSatisfy { if case .dropped = $0 { true } else { false } })
        for intake in [replayed, foreign, garbage, tooShort] {
            let confirmed = machine.received(intake, from: central)
            #expect(!confirmed)
        }
        #expect(!machine.phoneLinked && window == .accepting([5]))
    }

    @Test("a subscriber is confirmed only by what it wrote itself: the phone's ping or channel leaves a stranger unconfirmed")
    func confirmationIsPerSubscriber() throws {
        var window = ReplayWindow()
        let ping = SignalIntake.take(try phoneFrame(.ping, seq: 0), key: key, window: &window)
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        let stranger = UUID()
        machine.subscribed(stranger, payload: 244)
        machine.subscribed(phone, payload: 244)
        _ = machine.received(ping, from: phone)
        #expect(machine.confirmed == [phone] && machine.recipients(.phone) == [phone])
        #expect(machine.recipients(.anyone) == [phone], "once the phone is confirmed even a summon goes to it alone")

        var channel = GattPeripheralMachine()
        _ = channel.enable()
        channel.subscribed(stranger, payload: 244)
        channel.subscribed(phone, payload: 244)
        let byRecords = channel.authenticated(phone)
        #expect(byRecords && channel.confirmed == [phone], "a record on the phone's own channel confirms the phone only")
        let notSubscribed = channel.authenticated(UUID())
        #expect(!notSubscribed && channel.confirmed == [phone], "a channel whose central is not subscribed confirms nothing")
    }

    @Test("an unconfirmed subscriber receives summons but never a dismiss, a reply or a clip")
    func strangerGetsOnlySummons() throws {
        var window = ReplayWindow()
        let ping = SignalIntake.take(try phoneFrame(.ping, seq: 0), key: key, window: &window)
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        let stranger = UUID()
        machine.subscribed(stranger, payload: 244)
        let summon = try SignalFrame.seal(
            type: Signal.syncRequest.code, seq: 0, plaintext: Signal.syncRequest.plaintext(), key: key, direction: .macToPhone
        )
        #expect(machine.enqueue(summon, to: Signal.syncRequest.audience) == 0)
        #expect(machine.nextPending()?.recipients == [stranger])
        let dismiss = try SignalFrame.seal(
            type: 3, seq: 1, plaintext: Signal.dismiss(keyHash: hash).plaintext(), key: key, direction: .macToPhone
        )
        for audience in [Signal.dismiss(keyHash: hash), .reply(keyHash: hash, text: "ok"), .clipboardSmall(text: "x", sensitive: true)].map(\.audience) {
            #expect(machine.enqueue(dismiss, to: audience) == nil)
        }
        #expect(machine.pending.isEmpty)

        machine.subscribed(phone, payload: 244)
        _ = machine.received(ping, from: phone)
        #expect(machine.enqueue(dismiss, to: Signal.dismiss(keyHash: hash).audience) == 0)
        #expect(machine.nextPending()?.recipients == [phone], "the stranger is still subscribed and never gets it")
    }

    @Test("a confirmation ends with its subscription and never carries over to the next one")
    func confirmationEnds() throws {
        var window = ReplayWindow()
        let ping = SignalIntake.take(try phoneFrame(.ping, seq: 0), key: key, window: &window)
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        machine.subscribed(phone, payload: 182)
        _ = machine.received(ping, from: phone)
        machine.unsubscribed(phone)
        #expect(!machine.phoneLinked)
        machine.subscribed(phone, payload: 182)
        #expect(!machine.phoneLinked, "the new subscription waits for its own confirmation")

        _ = machine.received(ping, from: phone)
        machine.subscribed(phone, payload: 182)
        #expect(!machine.phoneLinked, "a repeated subscribe is a new subscription")

        _ = machine.received(ping, from: phone)
        _ = machine.radio(.poweredOff)
        #expect(!machine.phoneLinked, "the link is lost with the radio")

        _ = machine.radio(.poweredOn)
        machine.subscribed(phone, payload: 182)
        _ = machine.received(ping, from: phone)
        machine.revokeConfirmations()
        #expect(!machine.phoneLinked && machine.subscribed, "a pairing change revokes, the subscription stays")

        _ = machine.received(ping, from: phone)
        _ = machine.disable()
        #expect(!machine.phoneLinked && machine.confirmed.isEmpty, "the teardown ends it")
    }

    @Test("with two subscribers only the confirmed one is the phone; it leaving ends the link")
    func twoSubscribers() throws {
        var window = ReplayWindow()
        let ping = SignalIntake.take(try phoneFrame(.ping, seq: 0), key: key, window: &window)
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        let stranger = UUID()
        machine.subscribed(stranger, payload: 200)
        machine.subscribed(phone, payload: 244)
        _ = machine.received(ping, from: phone)
        #expect(machine.phoneLinked && machine.confirmed == [phone])
        machine.unsubscribed(phone)
        #expect(!machine.phoneLinked && machine.subscribed, "the stranger stays subscribed, but is not the phone")
        #expect(machine.payload(for: .phone) == nil && machine.payload(for: .anyone) == 200)
    }

    @Test("a subscriber below an MTU of 185 is in no audience, so the smallest MTU holds nothing back")
    func minimumMtuIgnored() throws {
        var window = ReplayWindow()
        let ping = SignalIntake.take(try phoneFrame(.ping, seq: 0), key: key, window: &window)
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        let stranger = UUID()
        machine.subscribed(phone, payload: 244)
        machine.subscribed(stranger, payload: 20)
        #expect(machine.payload(for: .anyone) == 244, "a summon is sized past the stranger even before the ping")
        #expect(machine.recipients(.anyone) == [phone])
        machine.subscribed(stranger, payload: GattPeripheralMachine.minimumPayload - 1)
        #expect(machine.payload(for: .anyone) == 244)
        _ = machine.received(ping, from: phone)
        #expect(machine.recipients(.phone) == [phone] && machine.payload(for: .phone) == 244)
        let paths = SignalPaths(
            phonePayload: machine.payload(for: .phone), summonPayload: machine.payload(for: .anyone), sessionUp: true
        )
        #expect(paths.carrier(frameBytes: SignalFrame.maxFrameBytes) == .gatt)
        #expect(machine.enqueue(Data(count: SignalFrame.maxFrameBytes), to: .anyone) == 0)
        #expect(machine.nextPending()?.recipients == [phone])

        var alone = GattPeripheralMachine()
        _ = alone.enable()
        alone.subscribed(stranger, payload: 20)
        #expect(alone.subscribed && alone.payload(for: .anyone) == nil, "subscribed, but nothing is sized for it")
        #expect(alone.enqueue(Data(count: 10), to: .anyone) == nil)
    }

    @Test("a queued frame keeps the recipients it was sized for and is dropped when they all leave")
    func queuedRecipients() throws {
        var window = ReplayWindow()
        let ping = SignalIntake.take(try phoneFrame(.ping, seq: 0), key: key, window: &window)
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        let phone = UUID()
        let stranger = UUID()
        machine.subscribed(phone, payload: 244)
        machine.subscribed(stranger, payload: 200)
        _ = machine.received(ping, from: phone)
        #expect(machine.enqueue(Data(count: 100), to: .anyone) == 0)
        machine.unsubscribed(phone)
        #expect(machine.payload(for: .anyone) == 200 && machine.pending.count == 1)
        let next = machine.nextPending()
        #expect(next == nil && machine.pending.isEmpty, "never sent to the stranger it was not sized for")
    }

    @Test("frames the stack refuses wait in order behind a short cap, the oldest out first")
    func notifyQueue() {
        var machine = GattPeripheralMachine()
        _ = machine.enable()
        machine.subscribed(UUID(), payload: 244)
        let frames = (0..<(GattPeripheralMachine.pendingCapacity + 2)).map { Data([UInt8($0)]) }
        #expect(machine.enqueue(frames[0], to: .anyone) == 0)
        guard let head = machine.nextPending() else {
            Issue.record("the queued frame comes out")
            return
        }
        #expect(head.frame == frames[0])
        machine.refused(head)
        #expect(machine.pending == [head])
        var dropped = 0
        for frame in frames.dropFirst() {
            dropped += machine.enqueue(frame, to: .anyone) ?? 0
        }
        #expect(dropped == 2 && machine.pending.count == GattPeripheralMachine.pendingCapacity)
        #expect(machine.pending.first?.frame == frames[2] && machine.pending.last?.frame == frames.last)
    }
}
