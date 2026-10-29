import Foundation

// The fields that decide whether a re-post alerts again (MirrorRendering.replacementAlerts).
nonisolated struct AlertContent: Equatable, Sendable {
    var appLabel: String
    var title: String
    var text: String

    init(_ info: NotificationInfo) {
        appLabel = info.appLabel
        title = info.title
        text = info.text
    }
}

nonisolated enum DismissVerdict: Equatable, Sendable {
    case send
    // Removed by the Mac on the phone's behalf, or tapped or replied to: not the user's dismissal.
    case notADismissal
    case alreadyPending
    // A copy with other visible text was posted since: new content for the user, not what they closed.
    case superseded
}

// A dismissal waiting for the phone's set to settle it, with what the user closed: the revision the
// phone gave that copy and its visible content.
nonisolated struct PendingDismissal: Equatable, Sendable {
    var since: ContinuousClock.Instant
    var revision: Int64?
    var content: AlertContent?
}

// What the phone's set or detail decided: the dismisses to send again, each at the revision the phone
// listed, and the notifications the mirror may take — a key whose dismissal is still due is left
// out, so what the user closed is not added back.
nonisolated struct DismissalSettlement: Equatable, Sendable {
    struct Due: Equatable, Sendable {
        var keyHash: String
        var revision: Int64?
    }

    var due: [Due] = []
    var kept: [NotificationInfo] = []
}

// Mac → phone dismissal bookkeeping. `expected` is what the Mac last saw of its own mirrors
// (delivered plus fresh posts); a request that leaves it without a callback is the user's dismissal,
// unless a tombstone says the Mac removed it or the user tapped or replied to it.
// Spec, Loop prevention: a dismissal stays pending — sent or not, a frame can get lost — until the
// phone's set no longer lists its key at what the user closed.
nonisolated struct DismissalBook: Sendable {
    static let pendingLifetime = Duration.seconds(24 * 60 * 60)
    static let pendingCapacity = 64

    private(set) var expected: [String: MirrorEntry] = [:]
    private var tombstones = Tombstones()
    // Memory only: a Mac app that restarts in between forgets them, and the phone's set adds them back.
    private var pending: [String: PendingDismissal] = [:]
    private var lastPosted: [String: AlertContent] = [:]

    var pendingCount: Int { pending.count }

    func pending(_ keyHash: String) -> PendingDismissal? {
        pending[keyHash]
    }

    // `table` is delivered merged with the fresh posts, so a just-posted request that lags the
    // delivered list is never read as vanished. The table becomes the new baseline.
    mutating func settle(on table: [String: MirrorEntry]) -> [MirrorEntry] {
        let vanished = expected.filter { table[$0.key] == nil }.values.sorted { $0.keyHash < $1.keyHash }
        expected = table
        return vanished
    }

    // Without a session a dismissal cannot reach the phone, so a read only adds to the baseline:
    // what went missing stays expected until the first read with a session settles it.
    mutating func extend(with table: [String: MirrorEntry]) {
        expected.merge(table) { _, new in new }
    }

    // With notifications off or hidden from Notification Center the delivered list is empty, and the
    // old baseline would read as every mirror dismissed at once once it shows again.
    mutating func forgetBaseline() {
        expected = [:]
    }

    // Records the dismissal as pending when the verdict is `send`.
    mutating func judge(
        _ keyHash: String, content: AlertContent?, revision: Int64? = nil, at now: ContinuousClock.Instant
    ) -> DismissVerdict {
        prune(at: now)
        if tombstones.contains(keyHash, at: now) { return .notADismissal }
        if pending[keyHash] != nil { return .alreadyPending }
        pending[keyHash] = PendingDismissal(since: now, revision: revision, content: content)
        while pending.count > Self.pendingCapacity, let oldest = pending.min(by: { $0.value.since < $1.value.since })?.key {
            pending[oldest] = nil
        }
        expected[keyHash] = nil
        lastPosted[keyHash] = nil
        return .send
    }

    // A vanished mirror is judged after the commands queued behind its read, so a tap or a reply
    // macOS delivered after removing it has set its tombstone first. The copy a tap or a reply acted
    // on is never a dismissal, however late it is judged; one posted after it is judged as usual.
    // A state-sync queued meanwhile may have posted the key again: with the same text the dismissal
    // still goes (and takes the re-add with it), with new text the user has not closed that yet.
    mutating func judgeVanished(
        _ entry: MirrorEntry, interacted: InteractedMemory, at now: ContinuousClock.Instant
    ) -> DismissVerdict {
        if interacted.coversRemoval(entry.keyHash) { return .notADismissal }
        if let latest = lastPosted[entry.keyHash], latest != AlertContent(entry.info) { return .superseded }
        return judge(entry.keyHash, content: AlertContent(entry.info), revision: entry.info.revision, at: now)
    }

    // Covers the Mac's own removals and a tap or a reply, both of which take the mirror out of NC.
    // A removal on the phone's behalf also settles a dismissal still pending for it.
    mutating func setAside(_ keyHash: String, at now: ContinuousClock.Instant) {
        tombstones.insert(keyHash, at: now)
        expected[keyHash] = nil
        lastPosted[keyHash] = nil
        pending[keyHash] = nil
    }

    // A click action that opened something on the Mac closes the phone's copy too, so the tap's
    // tombstone gives way — unless the tap is forgotten since (the phone removed the key, an
    // unpair, a re-add that alerted) or a copy with other text was posted since the click.
    mutating func judgeOpened(
        _ entry: MirrorEntry, interacted: InteractedMemory, at now: ContinuousClock.Instant
    ) -> DismissVerdict {
        guard interacted.contains(entry.keyHash) else { return .notADismissal }
        if let latest = lastPosted[entry.keyHash], latest != AlertContent(entry.info) { return .superseded }
        tombstones.remove(entry.keyHash)
        return judge(entry.keyHash, content: AlertContent(entry.info), revision: entry.info.revision, at: now)
    }

    // A new post supersedes whatever was recorded about the key's last removal.
    mutating func posted(_ keyHash: String, content: AlertContent) {
        tombstones.remove(keyHash)
        pending[keyHash] = nil
        lastPosted[keyHash] = content
    }

    // The phone's whole set decides every pending dismissal: a key it no longer lists is settled, and
    // each one it lists is decided as a detail is.
    mutating func settle(_ notifications: [NotificationInfo], at now: ContinuousClock.Instant) -> DismissalSettlement {
        prune(at: now)
        let listed = Set(notifications.map { Signal.keyHash(of: $0.key) })
        pending = pending.filter { listed.contains($0.key) }
        var settlement = DismissalSettlement()
        for info in notifications {
            if let due = decide(info) {
                settlement.due.removeAll { $0.keyHash == due.keyHash }
                settlement.due.append(due)
            } else {
                settlement.kept.append(info)
            }
        }
        return settlement
    }

    mutating func settle(detail info: NotificationInfo, at now: ContinuousClock.Instant) -> DismissalSettlement {
        prune(at: now)
        guard let due = decide(info) else { return DismissalSettlement(kept: [info]) }
        return DismissalSettlement(due: [due])
    }

    mutating func forgetAll() {
        expected = [:]
        tombstones = Tombstones()
        pending = [:]
        lastPosted = [:]
    }

    // A state-sync's re-add of a mirror its own read found gone waits for that mirror's judgment:
    // added now and dismissed a moment later, it would alert for nothing. One the phone lists with
    // other content is new to the user and goes ahead.
    static func holdingBack(
        _ notifications: [NotificationInfo], vanished: [MirrorEntry]
    ) -> (kept: [NotificationInfo], held: [NotificationInfo]) {
        guard !vanished.isEmpty else { return (notifications, []) }
        let gone = Dictionary(vanished.map { ($0.keyHash, AlertContent($0.info)) }, uniquingKeysWith: { _, last in last })
        var kept: [NotificationInfo] = []
        var held: [NotificationInfo] = []
        for info in notifications {
            if gone[Signal.keyHash(of: info.key)] == AlertContent(info) { held.append(info) } else { kept.append(info) }
        }
        return (kept, held)
    }

    // Still listed at the closed revision, or at another with the content the user closed: due again,
    // at the listed revision. Listed with other content: new to the user, the dismissal ends. Without
    // a revision on either side the content alone decides, and an unknown content anything listed.
    private mutating func decide(_ info: NotificationInfo) -> DismissalSettlement.Due? {
        let keyHash = Signal.keyHash(of: info.key)
        guard var record = pending[keyHash] else { return nil }
        let sameRevision = record.revision != nil && record.revision == info.revision
        let sameContent = record.content.map { $0 == AlertContent(info) } ?? true
        guard sameRevision || sameContent else {
            pending[keyHash] = nil
            return nil
        }
        record.revision = info.revision ?? record.revision
        pending[keyHash] = record
        return DismissalSettlement.Due(keyHash: keyHash, revision: record.revision)
    }

    private mutating func prune(at now: ContinuousClock.Instant) {
        pending = pending.filter { now - $0.value.since < Self.pendingLifetime }
    }
}

// Keys the user tapped or replied to on the Mac. macOS removes such a mirror itself while the phone
// keeps the notification — until a click action that opened something closes it there and forgets
// the tap — so the next active-set adds it back. After a tap that re-add is passive while the
// content is what the tap saw. After a reply the app's update is its answer to the user, so the
// first re-add within `replyQuiet` of the reply is passive whatever it shows, and only that one; a
// reply that failed is forgotten, so nothing stays silent behind it. Memory only, no timer (the
// window is a comparison), the oldest out past the cap.
nonisolated struct InteractedMemory: Equatable, Sendable {
    enum Interaction: Equatable, Sendable {
        case tap(AlertContent)
        case reply(at: ContinuousClock.Instant)
    }

    static let capacity = 64
    static let replyQuiet = Duration.seconds(30)

    private var interactions: [String: Interaction] = [:]
    private var order: [String] = []
    private var reposted: Set<String> = []

    var count: Int { order.count }

    func contains(_ keyHash: String) -> Bool {
        interactions[keyHash] != nil
    }

    // True while the copy the user acted on is the last one posted: its removal was the tap or the
    // reply, not a dismissal. A copy posted after the interaction can be dismissed like any other.
    func coversRemoval(_ keyHash: String) -> Bool {
        contains(keyHash) && !reposted.contains(keyHash)
    }

    mutating func recordTap(_ info: NotificationInfo) {
        record(Signal.keyHash(of: info.key), .tap(AlertContent(info)))
    }

    mutating func recordReply(_ keyHash: String, at now: ContinuousClock.Instant) {
        record(keyHash, .reply(at: now))
    }

    func readdIsQuiet(_ info: NotificationInfo, at now: ContinuousClock.Instant) -> Bool {
        switch interactions[Signal.keyHash(of: info.key)] {
        case .tap(let content): content == AlertContent(info)
        case .reply(let at): now - at < Self.replyQuiet
        case nil: false
        }
    }

    mutating func posted(_ keyHash: String) {
        guard contains(keyHash) else { return }
        reposted.insert(keyHash)
    }

    mutating func forget(_ keyHash: String) {
        guard interactions.removeValue(forKey: keyHash) != nil else { return }
        order.removeAll { $0 == keyHash }
        reposted.remove(keyHash)
    }

    mutating func forgetAll() {
        interactions = [:]
        order = []
        reposted = []
    }

    // A key the phone no longer lists has nothing left to come back.
    mutating func retain(_ present: Set<String>) {
        for keyHash in order where !present.contains(keyHash) {
            forget(keyHash)
        }
    }

    // Runs on the plan, before any post: a held re-add has taken its passive flag along already, so
    // a reply is used up by the hold just as by a post. A post that alerts ends a tap's quiet re-add.
    mutating func settle(after actions: [MirrorAction]) {
        for action in actions {
            switch action {
            case .post(let info, let alerting), .hold(let info, let alerting):
                let keyHash = Signal.keyHash(of: info.key)
                if alerting { forget(keyHash) }
                if case .reply = interactions[keyHash] { forget(keyHash) }
            case .remove, .cancel:
                break
            }
        }
    }

    private mutating func record(_ keyHash: String, _ interaction: Interaction) {
        forget(keyHash)
        interactions[keyHash] = interaction
        order.append(keyHash)
        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            interactions[oldest] = nil
            reposted.remove(oldest)
        }
    }
}
