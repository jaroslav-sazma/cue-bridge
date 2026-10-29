import CryptoKit
import Foundation
import Testing

// The Mac's half of a session end to end in-process: its real link machine, framing, frame codec and
// replay window, and the dismissal book, pending replies and sync coalescer that decide what it sends,
// over an in-memory carrier that can lose a frame, against a scripted phone. The app's actors only
// carry out what these decide; the phone's side is the launcher's to test.

private let chatKey = "0|com.example.chat|42|null|10123"
private let mailKey = "0|com.example.mail|7|null|10123"
private let chatHash = Signal.keyHash(of: chatKey)
private let mailHash = Signal.keyHash(of: mailKey)
private let r1: Int64 = 1_791_820_800_000
private let r2: Int64 = 1_791_820_860_000

private func note(_ key: String, text: String = "Are you coming?", revision: Int64) -> NotificationInfo {
    NotificationInfo(
        key: key, pkg: "com.example.chat", appLabel: "Example Chat", title: "Alice", text: text, when: revision,
        threadId: nil, canReply: true, isClearable: true, iconHash: nil, revision: revision
    )
}

private struct LoopbackError: Error {}

private struct Carrier {
    var toMac = Data()
    var toPhone = Data()
    var loseNextToPhone = false

    mutating func macWrites(_ message: BridgeMessage) throws {
        let frame = try TcpFrame.encode(message)
        if loseNextToPhone {
            loseNextToPhone = false
            return
        }
        toPhone.append(frame)
    }

    mutating func phoneWrites(_ message: BridgeMessage) throws {
        toMac.append(try TcpFrame.encode(message))
    }
}

// What the launcher does with the Mac's messages, reduced to the wire: it answers a sync-request with
// its set, applies a dismiss only at the revision it shows and rings for the key otherwise, and
// answers a reply.
private struct ScriptedPhone {
    let key: SymmetricKey
    var shade: [String: NotificationInfo] = [:]
    var answersReplies = true
    private var decoder = TcpFrameDecoder()
    private var window = ReplayWindow()
    private var seq: UInt32 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    var set: BridgeMessage { .activeSet(notifications: shade.values.sorted { $0.key < $1.key }) }

    mutating func read(_ bytes: Data) throws -> [BridgeMessage] {
        decoder.append(bytes)
        var answers: [BridgeMessage] = []
        while let event = try decoder.next() {
            guard case .message(let message) = event else { continue }
            switch message {
            case .syncRequest:
                answers.append(set)
            case .signal(let encoded):
                guard let frame = Data(base64Encoded: encoded) else { throw LoopbackError() }
                let opened = try SignalFrame.open(frame, key: key, direction: .macToPhone, window: window)
                window.record(opened.seq)
                let interpretation = Signal.interpret(type: opened.type, plaintext: opened.plaintext, direction: .macToPhone)
                guard case .valid(let signal) = interpretation else { continue }
                answers += try act(signal)
            default:
                break
            }
        }
        return answers
    }

    mutating func frame(_ signal: Signal) throws -> BridgeMessage {
        defer { seq += 1 }
        let sealed = try SignalFrame.seal(
            type: signal.code, seq: seq, plaintext: signal.plaintext(), key: key, direction: .phoneToMac
        )
        return .signal(frame: sealed.base64EncodedString())
    }

    private mutating func act(_ signal: Signal) throws -> [BridgeMessage] {
        switch signal {
        case .dismiss(let keyHash, let revision):
            guard let key = shade.keys.first(where: { Signal.keyHash(of: $0) == keyHash }) else { return [] }
            if let revision, shade[key]?.revision != revision { return [try frame(.notifPosted(keyHash: keyHash))] }
            shade[key] = nil
            return []
        case .reply(let keyHash, _):
            return answersReplies ? [try frame(.replyOk(keyHash: keyHash))] : []
        default:
            return []
        }
    }
}

private struct MacUnderTest {
    let key: SymmetricKey
    var book = DismissalBook()
    var replies = PendingReplies()
    var mirrored: [String: NotificationInfo] = [:]
    var confirmed: [String] = []
    var syncRequestsSent = 0
    private var machine = LinkMachine(transport: .tcp)
    private var coalescer = SyncCoalescer()
    private var decoder = TcpFrameDecoder()
    private var window = ReplayWindow()
    private var seq: UInt32 = 0
    private var sessionUp = false

    init(key: SymmetricKey) {
        self.key = key
    }

    mutating func connect(_ carrier: inout Carrier) throws {
        try carry(machine.connection(.ready(hasPeerCertificate: true)), &carrier, at: .now)
    }

    mutating func read(_ carrier: inout Carrier, at now: ContinuousClock.Instant) throws {
        decoder.append(carrier.toMac)
        carrier.toMac = Data()
        let context = LinkContext(isPinned: true, ceremony: .none, lastPairingModeExpired: false)
        while let event = try decoder.next() {
            guard case .message(let message) = event else { continue }
            try carry(machine.received(message, context: context), &carrier, at: now)
        }
    }

    // The user closes a mirror: judged, sent, and pending whatever becomes of the frame.
    mutating func userDismissed(
        _ info: NotificationInfo, _ carrier: inout Carrier, at now: ContinuousClock.Instant
    ) throws -> DismissVerdict {
        let keyHash = Signal.keyHash(of: info.key)
        let verdict = book.judge(keyHash, content: AlertContent(info), revision: info.revision, at: now)
        if verdict == .send {
            mirrored[keyHash] = nil
            try transmit(.dismiss(keyHash: keyHash, revision: book.pending(keyHash)?.revision), &carrier)
        }
        return verdict
    }

    mutating func userReplied(
        _ info: NotificationInfo, _ text: String, _ carrier: inout Carrier, at now: ContinuousClock.Instant
    ) throws {
        guard case .inline(let signal) = try ReplyEncoding.plan(key: info.key, text: text) else { throw LoopbackError() }
        replies.record(Signal.keyHash(of: info.key), .init(appLabel: info.appLabel, title: info.title), at: now)
        try transmit(signal, &carrier)
    }

    mutating func woke(_ carrier: inout Carrier) throws -> SyncAsk {
        try ask(&carrier)
    }

    private mutating func ask(_ carrier: inout Carrier) throws -> SyncAsk {
        let asked = coalescer.ask(sessionUp: sessionUp)
        if asked == .send { try requestSync(&carrier) }
        return asked
    }

    private mutating func requestSync(_ carrier: inout Carrier) throws {
        syncRequestsSent += 1
        try carrier.macWrites(.syncRequest)
    }

    private mutating func carry(
        _ effects: [LinkEffect], _ carrier: inout Carrier, at now: ContinuousClock.Instant
    ) throws {
        for effect in effects {
            switch effect {
            case .send(let message):
                try carrier.macWrites(message)
            case .establishSession:
                sessionUp = true
                coalescer.sessionStarted()
            case .toSession(let message):
                try inSession(message, &carrier, at: now)
            default:
                break
            }
        }
    }

    private mutating func inSession(
        _ message: BridgeMessage, _ carrier: inout Carrier, at now: ContinuousClock.Instant
    ) throws {
        switch message {
        case .activeSet(let notifications):
            let settlement = book.settle(notifications, at: now)
            mirrored = Dictionary(
                settlement.kept.map { (Signal.keyHash(of: $0.key), $0) }, uniquingKeysWith: { _, last in last }
            )
            for due in settlement.due {
                try transmit(.dismiss(keyHash: due.keyHash, revision: due.revision), &carrier)
            }
            if coalescer.activeSetReceived() { try requestSync(&carrier) }
        case .signal(let encoded):
            guard let frame = Data(base64Encoded: encoded) else { throw LoopbackError() }
            guard case .accepted(_, .valid(let signal)) = SignalIntake.take(frame, key: key, window: &window) else { return }
            switch signal {
            case .notifPosted:
                _ = try ask(&carrier)
            case .replyOk(let keyHash):
                if replies.take(keyHash) != nil { confirmed.append(keyHash) }
            case .replyError(let keyHash, _):
                replies.take(keyHash)
            default:
                break
            }
        default:
            break
        }
    }

    private mutating func transmit(_ signal: Signal, _ carrier: inout Carrier) throws {
        defer { seq += 1 }
        let frame = try SignalFrame.seal(
            type: signal.code, seq: seq, plaintext: signal.plaintext(), key: key, direction: .macToPhone
        )
        try carrier.macWrites(.signal(frame: frame.base64EncodedString()))
    }
}

private struct Loopback {
    var carrier = Carrier()
    var mac: MacUnderTest
    var phone: ScriptedPhone

    init(shade: [NotificationInfo]) {
        let key = SymmetricKey(size: .bits256)
        mac = MacUnderTest(key: key)
        phone = ScriptedPhone(key: key)
        phone.shade = Dictionary(uniqueKeysWithValues: shade.map { ($0.key, $0) })
    }

    // The hello exchange, then the phone's set unprompted.
    mutating func open(at now: ContinuousClock.Instant) throws {
        try mac.connect(&carrier)
        try carrier.phoneWrites(.hello(version: BridgeProtocol.version))
        try carrier.phoneWrites(phone.set)
        try pump(at: now)
    }

    mutating func phoneRings(_ keyHash: String, at now: ContinuousClock.Instant) throws {
        let doorbell = try phone.frame(.notifPosted(keyHash: keyHash))
        try carrier.phoneWrites(doorbell)
        try pump(at: now)
    }

    mutating func pump(at now: ContinuousClock.Instant) throws {
        while !carrier.toMac.isEmpty || !carrier.toPhone.isEmpty {
            try mac.read(&carrier, at: now)
            let bytes = carrier.toPhone
            carrier.toPhone = Data()
            for answer in try phone.read(bytes) {
                try carrier.phoneWrites(answer)
            }
        }
    }
}

@Suite("Session loopback")
struct ConversationLoopbackTests {
    private let start = ContinuousClock.now

    @Test("a dismiss lost on the way stays pending, goes again with the next set and settles once unlisted")
    func lostDismiss() throws {
        let chat = note(chatKey, revision: r1)
        var loop = Loopback(shade: [chat, note(mailKey, text: "Invoice", revision: r1)])
        try loop.open(at: start)
        #expect(loop.mac.mirrored.count == 2)

        loop.carrier.loseNextToPhone = true
        let verdict = try loop.mac.userDismissed(chat, &loop.carrier, at: start)
        try loop.pump(at: start)
        #expect(verdict == .send)
        #expect(loop.phone.shade[chatKey] != nil, "the dismiss was lost")

        try loop.phoneRings(mailHash, at: start + .seconds(60))
        #expect(loop.phone.shade[chatKey] == nil, "sent again with the set that still listed it, and applied")
        #expect(loop.mac.mirrored[chatHash] == nil, "what the user closed was never added back")
        #expect(loop.mac.book.pendingCount == 1, "pending until a set no longer lists it")

        try loop.phoneRings(mailHash, at: start + .seconds(61))
        #expect(loop.mac.book.pendingCount == 0)
        #expect(loop.mac.mirrored.keys.sorted() == [mailHash])
    }

    @Test("a dismiss for a post the phone replaced is ignored there, and goes again at the new revision")
    func newerRevision() throws {
        let chat = note(chatKey, revision: r1)
        var loop = Loopback(shade: [chat])
        try loop.open(at: start)
        loop.phone.shade[chatKey] = note(chatKey, revision: r2)

        _ = try loop.mac.userDismissed(chat, &loop.carrier, at: start)
        try loop.pump(at: start)

        #expect(loop.phone.shade[chatKey] == nil, "the phone rang for the key, its set listed r2, the dismiss went at r2")
        #expect(loop.mac.book.pending(chatHash)?.revision == r2)
        #expect(loop.mac.mirrored.isEmpty)
    }

    @Test("a post with new content meets the dismiss on the phone: it stays there and comes back on the Mac")
    func newContent() throws {
        let chat = note(chatKey, revision: r1)
        var loop = Loopback(shade: [chat])
        try loop.open(at: start)
        let newer = note(chatKey, text: "Are you there?", revision: r2)
        loop.phone.shade[chatKey] = newer

        _ = try loop.mac.userDismissed(chat, &loop.carrier, at: start)
        try loop.pump(at: start)

        #expect(loop.phone.shade[chatKey] == newer)
        #expect(loop.mac.mirrored[chatHash] == newer)
        #expect(loop.mac.book.pendingCount == 0)
    }

    @Test("a reply waits for reply-ok; one never answered is reported as not confirmed")
    func replies() throws {
        let chat = note(chatKey, revision: r1)
        var loop = Loopback(shade: [chat])
        try loop.open(at: start)

        try loop.mac.userReplied(chat, "On my way", &loop.carrier, at: start)
        #expect(loop.mac.replies.count == 1)
        try loop.pump(at: start)
        #expect(loop.mac.confirmed == [chatHash] && loop.mac.replies.count == 0)

        loop.phone.answersReplies = false
        let sent = start + .seconds(40)
        try loop.mac.userReplied(chat, "Hello?", &loop.carrier, at: sent)
        try loop.pump(at: sent)
        let early = loop.mac.replies.overdue(at: sent + .seconds(29))
        let late = loop.mac.replies.overdue(at: sent + PendingReplies.answerDeadline)
        #expect(early.isEmpty)
        #expect(late.map(\.keyHash) == [chatHash])
        let notice = LocalNotices.replyFailed(late.first?.record, .unconfirmed)
        #expect(notice.title == "Reply not confirmed" && notice.subtitle == "Example Chat — Alice")
    }

    @Test("a wake asks for one set, and wakes before it arrives fold into exactly one more")
    func wake() throws {
        var loop = Loopback(shade: [note(chatKey, revision: r1)])
        try loop.open(at: start)

        var asks: [SyncAsk] = []
        for _ in 0..<3 {
            asks.append(try loop.mac.woke(&loop.carrier))
        }
        try loop.pump(at: start)

        #expect(asks == [.send, .folded, .folded])
        #expect(loop.mac.syncRequestsSent == 2, "the one asked for and one more after its set")

        var away = Loopback(shade: [])
        let unconnected = try away.mac.woke(&away.carrier)
        #expect(unconnected == .summon && away.carrier.toPhone.isEmpty, "without a session the phone is summoned over GATT")
    }
}
