import CryptoKit
import Foundation

nonisolated enum SignalCarrier: String, Equatable, Sendable {
    case gatt
    case tcp
}

// The route is decided before a seq is spent: GATT to the confirmed phone when the frame fits its
// payload (MTU − 3), else the session, else — for a summon only — GATT to the subscribers not
// confirmed yet: sealed, so harmless, and the only way a summon reaches a phone whose ping is still on
// its way. Everything else a frame can carry acts on the user's behalf and goes to the confirmed phone
// or not over GATT at all, since a stranger would take it and drop it.
nonisolated struct SignalPaths: Equatable, Sendable {
    var phonePayload: Int?
    var summonPayload: Int?
    var sessionUp: Bool

    static func frameBytes(plaintextBytes: Int) -> Int {
        SignalFrame.headerBytes + plaintextBytes + SignalFrame.tagBytes
    }

    func carrier(frameBytes: Int, audience: GattAudience = .phone) -> SignalCarrier? {
        if let phonePayload, frameBytes <= phonePayload { return .gatt }
        if sessionUp { return .tcp }
        guard audience == .anyone, let summonPayload, frameBytes <= summonPayload else { return nil }
        return .gatt
    }

    func carrier(for signal: Signal) throws -> SignalCarrier? {
        carrier(frameBytes: Self.frameBytes(plaintextBytes: try signal.plaintext().count), audience: signal.audience)
    }

    // Nil when nothing can leave. A reply-text with no session is kept for the next one: its `reply`
    // frame with the tcp flag goes over GATT now and makes the phone open that session.
    func plan(_ reply: ReplyEncoding) throws -> [OutboundStep]? {
        switch reply {
        case .inline(let signal):
            guard let carrier = try carrier(for: signal) else { return nil }
            return [.signal(signal, carrier)]
        case .overTcp(let signal, let message):
            guard let carrier = try carrier(for: signal) else { return nil }
            return [.signal(signal, carrier), sessionUp ? .message(message) : .keepForNextSession(message)]
        }
    }

    func plan(_ clip: ClipboardEncoding) throws -> [OutboundStep]? {
        switch clip {
        case .small(let signal):
            guard let carrier = try carrier(for: signal) else { return nil }
            return [.signal(signal, carrier)]
        case .overTcp(let message):
            return sessionUp ? [.message(message)] : nil
        }
    }
}

// `phone`: the confirmed subscribers only. `anyone`: those, or while none is confirmed every
// subscriber, for the summon that has to reach a phone before its ping has.
nonisolated enum GattAudience: Equatable, Sendable {
    case phone
    case anyone
}

nonisolated extension Signal {
    var audience: GattAudience { self == .syncRequest ? .anyone : .phone }
}

nonisolated enum OutboundStep: Equatable, Sendable {
    case signal(Signal, SignalCarrier)
    case message(BridgeMessage)
    case keepForNextSession(BridgeMessage)
}

// The one intake for phone → Mac frames, whether a `signal` message or a doorbell write brought them:
// the receiving rules in spec order, and only an accepted frame is recorded in the shared window.
nonisolated enum SignalIntake: Equatable, Sendable {
    case dropped(SignalRejection)
    case accepted(OpenedSignal, SignalInterpretation)

    static func take(_ frame: Data, key: SymmetricKey, window: inout ReplayWindow) -> SignalIntake {
        do {
            let opened = try SignalFrame.open(frame, key: key, direction: .phoneToMac, window: window)
            window.record(opened.seq)
            return .accepted(
                opened, Signal.interpret(type: opened.type, plaintext: opened.plaintext, direction: .phoneToMac)
            )
        } catch {
            return .dropped(error)
        }
    }
}

// Spec, `reply-text`: "otherwise on the next one", provided it starts before the reply's answer is
// overdue: a text that waited longer has been reported to the user as not confirmed, and arriving
// now it would surprise them. Each text goes out once, on the next session's first active-set — a
// Send to Mac connection, which the phone only drains, never sends one. Memory only, the oldest out
// past the cap; unpairing and a new pairing forget them.
nonisolated struct PendingReplyTexts: Equatable, Sendable {
    static let capacity = 16

    private struct Waiting: Equatable, Sendable {
        var message: BridgeMessage
        var since: ContinuousClock.Instant
    }

    private var waiting: [Waiting] = []

    var count: Int { waiting.count }

    var messages: [BridgeMessage] { waiting.map(\.message) }

    // Returns how many older texts the cap pushed out.
    @discardableResult
    mutating func keep(_ message: BridgeMessage, at now: ContinuousClock.Instant = .now) -> Int {
        waiting.append(Waiting(message: message, since: now))
        let overflow = max(0, waiting.count - Self.capacity)
        waiting.removeFirst(overflow)
        return overflow
    }

    mutating func takeAll(at now: ContinuousClock.Instant = .now) -> [BridgeMessage] {
        defer { waiting = [] }
        return waiting.filter { now - $0.since < PendingReplies.answerDeadline }.map(\.message)
    }

    mutating func forgetAll() {
        waiting = []
    }
}

// The Mac's GATT peripheral as a pure machine; the CoreBluetooth shell carries out the effects and
// feeds the manager's callbacks back. The service is (re)added whenever the radio is powered on —
// CoreBluetooth clears the database and stops advertising below that — and advertising starts once
// the service is in. Notifications the stack refuses wait in a short queue for its ready callback.
// Spec, L2CAP transport: while paired the L2CAP channel is published first and the service waits
// for its PSM, so the `psm` characteristic is in the service from the start rather than forcing a
// re-add; a service that carries another PSM than the current one (or one while unpaired) is added
// again, which ends its subscriptions. A failed publish leaves the service without `psm` until the
// next power cycle. Whether CoreBluetooth drops a published channel with the radio is not
// documented, so the PSM from before a power cycle is released before the next publish.
// Spec, GATT transport: a subscription is not an identity. A subscriber is confirmed as the phone
// only by a frame it wrote itself that the intake accepted — a doorbell write, or a record on the
// L2CAP channel it opened — and only until that subscription ends. A frame is sized for and notified
// to its audience alone, so a stranger never receives what acts for the user, and a subscriber whose
// payload is below the floor of an MTU of 185 is in no audience, so one with the smallest MTU cannot
// hold the phone's frames back. Each queued frame keeps the recipients it was sized for and goes to
// those of them still subscribed, or nowhere.
nonisolated struct GattPeripheralMachine: Equatable, Sendable {
    static let pendingCapacity = 8
    static let minimumPayload = 182

    struct Outgoing: Equatable, Sendable {
        var frame: Data
        var recipients: Set<UUID>
    }

    enum Radio: String, Equatable, Sendable {
        case unknown
        case resetting
        case unsupported
        case unauthorized
        case poweredOff = "powered off"
        case poweredOn = "powered on"
    }

    enum Progress: Equatable, Sendable {
        case idle
        case adding
        case added
        case failed(String)
    }

    enum Channel: Equatable, Sendable {
        case idle
        case publishing
        case published(psm: UInt16)
        case failed(String)

        var psm: UInt16? {
            if case .published(let psm) = self { return psm }
            return nil
        }
    }

    enum Effect: Equatable, Sendable {
        case createManager
        // Removes whatever the manager still holds first, so the service is never in twice. With a
        // PSM the service carries the `psm` characteristic.
        case addService(psm: UInt16?)
        case startAdvertising
        case publishChannel
        case unpublishChannel(UInt16)
        // Stops advertising, removes the service and releases the manager.
        case teardown
    }

    private(set) var enabled = false
    private(set) var paired = false
    private(set) var hasManager = false
    private(set) var radio = Radio.unknown
    private(set) var service = Progress.idle
    private(set) var advertising = Progress.idle
    private(set) var channel = Channel.idle
    // The PSM the service in the database, or the one being added, carries.
    private(set) var servicePsm: UInt16?
    private var stalePsm: UInt16?
    private(set) var centrals: [UUID: Int] = [:]
    private(set) var confirmed: Set<UUID> = []
    private(set) var pending: [Outgoing] = []
    // Counts the times a service added again ended the subscriptions, which the phone did not do.
    private(set) var serviceReadds = 0

    func recipients(_ audience: GattAudience) -> Set<UUID> {
        let eligible = Set(centrals.filter { $0.value >= Self.minimumPayload }.keys)
        let phone = confirmed.intersection(eligible)
        return audience == .anyone && phone.isEmpty ? eligible : phone
    }

    func payload(for audience: GattAudience) -> Int? {
        recipients(audience).compactMap { centrals[$0] }.min()
    }

    var subscribed: Bool { !centrals.isEmpty }
    var phoneLinked: Bool { !confirmed.isEmpty }
    var isAdvertising: Bool { advertising == .added }

    mutating func enable() -> [Effect] {
        guard !enabled else { return [] }
        enabled = true
        guard hasManager else {
            hasManager = true
            return [.createManager]
        }
        return proceed()
    }

    mutating func disable() -> [Effect] {
        guard enabled else { return [] }
        let published = channel.psm
        self = GattPeripheralMachine()
        return (published.map { [.unpublishChannel($0)] } ?? []) + [.teardown]
    }

    mutating func setPaired(_ paired: Bool) -> [Effect] {
        guard enabled, paired != self.paired else { return [] }
        self.paired = paired
        return proceed()
    }

    mutating func radio(_ state: Radio) -> [Effect] {
        guard enabled else { return [] }
        radio = state
        guard state == .poweredOn else {
            if let psm = channel.psm { stalePsm = psm }
            service = .idle
            servicePsm = nil
            advertising = .idle
            channel = .idle
            centrals = [:]
            confirmed = []
            pending = []
            return []
        }
        return proceed()
    }

    // A publish that comes back after the bridge was unpaired is released at once.
    mutating func channelPublished(psm: UInt16, error: String?) -> [Effect] {
        guard enabled, channel == .publishing else { return [] }
        if let error {
            channel = .failed(error)
            return proceed()
        }
        guard paired else {
            channel = .idle
            return [.unpublishChannel(psm)] + proceed()
        }
        channel = .published(psm: psm)
        return proceed()
    }

    mutating func serviceAdded(error: String?) -> [Effect] {
        guard enabled, service == .adding else { return [] }
        if let error {
            service = .failed(error)
            return []
        }
        service = .added
        return proceed()
    }

    mutating func advertisingStarted(error: String?) -> [Effect] {
        guard enabled, advertising == .adding else { return [] }
        advertising = error.map(Progress.failed) ?? .added
        return []
    }

    // A repeated subscribe is a new subscription: what confirmed the previous one does not carry over.
    mutating func subscribed(_ central: UUID, payload: Int) {
        guard enabled else { return }
        centrals[central] = payload
        confirmed.remove(central)
    }

    mutating func unsubscribed(_ central: UUID) {
        centrals[central] = nil
        confirmed.remove(central)
        if centrals.isEmpty { pending = [] }
    }

    // A doorbell write from `central` that went through the intake. True when it confirmed a
    // subscription not confirmed before; a dropped frame or a writer that is not subscribed never does.
    mutating func received(_ intake: SignalIntake, from central: UUID) -> Bool {
        guard case .accepted = intake else { return false }
        return authenticated(central)
    }

    // `central` wrote something that opened under the pairing's key, such as a record on its own
    // L2CAP channel. True when that confirmed a subscription not confirmed before.
    mutating func authenticated(_ central: UUID) -> Bool {
        guard centrals[central] != nil else { return false }
        return confirmed.insert(central).inserted
    }

    // A new pairing or an unpairing: confirmations were made under the old key.
    mutating func revokeConfirmations() {
        confirmed = []
    }

    // Returns how many older frames the cap pushed out, or nil when the frame is refused: the audience
    // is empty or the frame does not fit its payload.
    mutating func enqueue(_ frame: Data, to audience: GattAudience) -> Int? {
        guard let payload = payload(for: audience), frame.count <= payload else { return nil }
        pending.append(Outgoing(frame: frame, recipients: recipients(audience)))
        let overflow = max(0, pending.count - Self.pendingCapacity)
        pending.removeFirst(overflow)
        return overflow
    }

    mutating func nextPending() -> Outgoing? {
        while !pending.isEmpty {
            var next = pending.removeFirst()
            next.recipients.formIntersection(centrals.keys)
            if !next.recipients.isEmpty { return next }
        }
        return nil
    }

    // The stack's transmit queue was full: the frame just taken goes back to the front and waits for
    // the ready callback.
    mutating func refused(_ outgoing: Outgoing) {
        guard subscribed else { return }
        pending.insert(outgoing, at: 0)
    }

    private mutating func proceed() -> [Effect] {
        guard enabled, radio == .poweredOn else { return [] }
        var effects: [Effect] = []
        if let stale = stalePsm {
            stalePsm = nil
            effects.append(.unpublishChannel(stale))
        }
        switch (paired, channel) {
        case (true, .idle):
            channel = .publishing
            return effects + [.publishChannel]
        case (true, .publishing):
            return effects
        case (false, .published(let psm)):
            channel = .idle
            effects.append(.unpublishChannel(psm))
        case (false, .failed):
            channel = .idle
        default:
            break
        }
        let wanted = paired ? channel.psm : nil
        switch service {
        case .idle:
            effects += addService(psm: wanted)
        case .added where servicePsm != wanted:
            effects += addService(psm: wanted)
        case .added where advertising == .idle:
            advertising = .adding
            effects.append(.startAdvertising)
        default:
            break
        }
        return effects
    }

    // A service added again drops the subscriptions to the old one.
    private mutating func addService(psm: UInt16?) -> [Effect] {
        if service == .added {
            centrals = [:]
            confirmed = []
            pending = []
            serviceReadds += 1
        }
        service = .adding
        servicePsm = psm
        return [.addService(psm: psm)]
    }
}
