import CryptoKit
import Foundation

// `pending` marks a notification held back for its icon: counted as mirrored, not yet in NC.
nonisolated struct MirrorEntry: Equatable, Sendable {
    var info: NotificationInfo
    var hasIcon: Bool
    var pending = false

    var keyHash: String { Signal.keyHash(of: info.key) }
}

// What a mirrored notification shows. Anything else (`when`, `isClearable`) changing is not a
// reason to replace it, so an unchanged notification never alerts again.
nonisolated struct RenderedContent: Equatable, Sendable {
    var appLabel: String
    var title: String
    var text: String
    var threadId: String?
    var iconHash: String?
    var canReply: Bool

    init(_ info: NotificationInfo) {
        appLabel = info.appLabel
        title = info.title
        text = info.text
        threadId = info.threadId
        iconHash = info.iconHash
        canReply = info.canReply
    }
}

nonisolated enum MirrorRendering {
    static func title(_ info: NotificationInfo) -> String {
        info.title.isEmpty ? info.appLabel : "\(info.appLabel) — \(info.title)"
    }

    static func threadIdentifier(_ info: NotificationInfo) -> String {
        if let threadId = info.threadId, !threadId.isEmpty { return threadId }
        return info.pkg
    }

    // A replacement alerts again only when its visible text changed; a new icon, thread or reply
    // ability alone is applied quietly.
    static func replacementAlerts(old: NotificationInfo, new: NotificationInfo) -> Bool {
        old.appLabel != new.appLabel || old.title != new.title || old.text != new.text
    }
}

nonisolated struct MirrorUpdate: Equatable, Sendable {
    var old: MirrorEntry
    var new: NotificationInfo
}

nonisolated struct StateSyncDiff: Equatable, Sendable {
    var added: [NotificationInfo] = []
    var updated: [MirrorUpdate] = []
    var removed: [String] = []
    var untouched: [MirrorEntry] = []

    // `mirror` is keyed by key hash. A key repeated in the set counts once, with its last content.
    static func compute(mirror: [String: MirrorEntry], activeSet: [NotificationInfo]) -> StateSyncDiff {
        var diff = StateSyncDiff()
        let incoming = unique(activeSet)
        let present = Set(incoming.map { Signal.keyHash(of: $0.key) })
        for info in incoming {
            diff.apply(info, against: mirror)
        }
        diff.removed = mirror.keys.filter { !present.contains($0) }.sorted()
        return diff
    }

    static func upsert(_ info: NotificationInfo, mirror: [String: MirrorEntry]) -> StateSyncDiff {
        var diff = StateSyncDiff()
        diff.apply(info, against: mirror)
        return diff
    }

    private mutating func apply(_ info: NotificationInfo, against mirror: [String: MirrorEntry]) {
        guard let existing = mirror[Signal.keyHash(of: info.key)] else {
            added.append(info)
            return
        }
        if RenderedContent(existing.info) == RenderedContent(info) {
            untouched.append(existing)
        } else {
            updated.append(MirrorUpdate(old: existing, new: info))
        }
    }

    private static func unique(_ notifications: [NotificationInfo]) -> [NotificationInfo] {
        var order: [String] = []
        var latest: [String: NotificationInfo] = [:]
        for info in notifications {
            let hash = Signal.keyHash(of: info.key)
            if latest.updateValue(info, forKey: hash) == nil { order.append(hash) }
        }
        return order.compactMap { latest[$0] }
    }
}

// A request just added can be missing from getDeliveredNotifications() for about 2 s, and a
// replacement made milliseconds after its add for over 15 s, showing nothing or its old content
// meanwhile. So what the Mac posted overrides the delivered list until a read has seen exactly that
// entry delivered; the cap is only a safety valve, after which the delivered list decides alone.
nonisolated struct RecentPosts: Sendable {
    static let cap = Duration.seconds(60)

    struct Merge: Equatable, Sendable {
        var table: [String: MirrorEntry]
        // Leave the overlay with this read: `seen` delivered as posted, `expired` past the cap.
        var seen: [String] = []
        var expired: [String] = []
    }

    private struct Post: Sendable {
        var entry: MirrorEntry
        var at: ContinuousClock.Instant
    }

    private var posts: [String: Post] = [:]

    var keyHashes: [String] { Array(posts.keys) }

    mutating func record(_ entry: MirrorEntry, at instant: ContinuousClock.Instant) {
        posts[entry.keyHash] = Post(entry: entry, at: instant)
    }

    mutating func forget(_ keyHash: String) {
        posts[keyHash] = nil
    }

    mutating func forgetAll() {
        posts = [:]
    }

    mutating func merged(over delivered: [String: MirrorEntry], at now: ContinuousClock.Instant) -> Merge {
        var merge = Merge(table: delivered)
        for hash in posts.keys.sorted() {
            guard let post = posts[hash] else { continue }
            if delivered[hash] == post.entry {
                merge.seen.append(hash)
                posts[hash] = nil
            } else if now - post.at >= Self.cap {
                merge.expired.append(hash)
                posts[hash] = nil
            } else {
                merge.table[hash] = post.entry
            }
        }
        return merge
    }
}

// What left Notification Center without being the user's dismissal — removed on the phone's behalf,
// tapped or replied to — so it is never reported back as one (spec "Loop prevention": in memory,
// at least 5 s).
nonisolated struct Tombstones: Sendable {
    static let lifetime = Duration.seconds(10)

    private var entries: [String: ContinuousClock.Instant] = [:]

    mutating func insert(_ keyHash: String, at instant: ContinuousClock.Instant) {
        entries[keyHash] = instant
    }

    mutating func remove(_ keyHash: String) {
        entries[keyHash] = nil
    }

    mutating func contains(_ keyHash: String, at now: ContinuousClock.Instant) -> Bool {
        entries = entries.filter { now - $0.value < Self.lifetime }
        return entries[keyHash] != nil
    }
}

// The mirror's state lives in Notification Center itself: each request's userInfo carries
// everything the diff needs, so the table survives the app being killed.
nonisolated extension MirrorEntry {
    static let marker = "cue.mirror"
    static let format = 1

    var userInfo: [String: Any] {
        var info: [String: Any] = [
            Self.marker: Self.format,
            "key": self.info.key,
            "pkg": self.info.pkg,
            "appLabel": self.info.appLabel,
            "title": self.info.title,
            "text": self.info.text,
            "when": self.info.when,
            "canReply": self.info.canReply,
            "isClearable": self.info.isClearable,
            "icon": hasIcon,
        ]
        if let threadId = self.info.threadId { info["threadId"] = threadId }
        if let iconHash = self.info.iconHash { info["iconHash"] = iconHash }
        if let revision = self.info.revision { info["r"] = revision }
        return info
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard (userInfo[Self.marker] as? Int) == Self.format,
              let key = userInfo["key"] as? String,
              let pkg = userInfo["pkg"] as? String,
              let appLabel = userInfo["appLabel"] as? String,
              let title = userInfo["title"] as? String,
              let text = userInfo["text"] as? String,
              let when = userInfo["when"] as? Int64,
              let canReply = userInfo["canReply"] as? Bool,
              let isClearable = userInfo["isClearable"] as? Bool,
              let hasIcon = userInfo["icon"] as? Bool
        else { return nil }
        self.init(
            info: NotificationInfo(
                key: key, pkg: pkg, appLabel: appLabel, title: title, text: text, when: when,
                threadId: userInfo["threadId"] as? String, canReply: canReply, isClearable: isClearable,
                iconHash: userInfo["iconHash"] as? String, revision: userInfo["r"] as? Int64
            ),
            hasIcon: hasIcon
        )
    }
}

nonisolated enum IconHash {
    // The hash names a file in the cache, so nothing but 64 lowercase hex digits is ever used.
    static func isWellFormed(_ hash: String) -> Bool {
        Fingerprint.isWellFormed(hash)
    }

    static func of(_ png: Data) -> String {
        Data(SHA256.hash(data: png)).hex
    }

    static func verifies(_ hash: String, _ png: Data) -> Bool {
        isWellFormed(hash) && of(png) == hash
    }
}

// Icons asked for on one connection: each missing hash once, and only an asked-for icon is taken.
nonisolated struct IconRequests: Sendable {
    private var asked: Set<String> = []

    mutating func toRequest(_ notifications: [NotificationInfo], isCached: (String) -> Bool) -> [String] {
        var hashes: [String] = []
        for hash in notifications.compactMap(\.iconHash)
        where IconHash.isWellFormed(hash) && !asked.contains(hash) && !isCached(hash) {
            asked.insert(hash)
            hashes.append(hash)
        }
        return hashes
    }

    func wasRequested(_ hash: String) -> Bool {
        asked.contains(hash)
    }
}

// A request replaced about 10 ms after its add went missing from getDeliveredNotifications() for
// over 15 s and was added again with a banner. So a notification whose icon is on its way is never
// posted and then replaced: it is held and posted once.
nonisolated struct IconHold: Sendable {
    struct Held: Equatable, Sendable {
        var info: NotificationInfo
        var alerting: Bool

        var keyHash: String { Signal.keyHash(of: info.key) }
    }

    private var held: [String: Held] = [:]

    var isEmpty: Bool { held.isEmpty }

    subscript(keyHash: String) -> Held? { held[keyHash] }

    var all: [Held] { Self.ordered(held.values) }

    func overlaid(on shown: [String: MirrorEntry]) -> [String: MirrorEntry] {
        var table = shown
        for (hash, entry) in held {
            table[hash] = MirrorEntry(info: entry.info, hasIcon: false, pending: true)
        }
        return table
    }

    mutating func hold(_ info: NotificationInfo, alerting: Bool) {
        held[Signal.keyHash(of: info.key)] = Held(info: info, alerting: alerting)
    }

    @discardableResult
    mutating func cancel(_ keyHash: String) -> Held? {
        held.removeValue(forKey: keyHash)
    }

    mutating func release(iconHash: String) -> [Held] {
        let released = held.values.filter { $0.info.iconHash == iconHash }
        for entry in released {
            held[entry.keyHash] = nil
        }
        return Self.ordered(released)
    }

    mutating func releaseAll() -> [Held] {
        defer { held = [:] }
        return all
    }

    // A post takes its notification out of the hold just as a cancel does.
    mutating func apply(_ actions: [MirrorAction]) {
        for action in actions {
            switch action {
            case .hold(let info, let alerting):
                hold(info, alerting: alerting)
            case .post(let info, _):
                cancel(Signal.keyHash(of: info.key))
            case .cancel(let keyHash):
                cancel(keyHash)
            case .remove:
                break
            }
        }
    }

    private static func ordered(_ entries: some Sequence<Held>) -> [Held] {
        entries.sorted { ($0.info.when, $0.keyHash) < ($1.info.when, $1.keyHash) }
    }
}

nonisolated enum MirrorAction: Equatable, Sendable {
    case post(NotificationInfo, alerting: Bool)
    case hold(NotificationInfo, alerting: Bool)
    case remove(keyHash: String)
    case cancel(keyHash: String)

    static func posting(_ held: [IconHold.Held]) -> [MirrorAction] {
        held.map { .post($0.info, alerting: $0.alerting) }
    }
}

// `shown` is what NC holds (delivered plus recent posts); held notifications count as mirrored, so
// the diff runs against both. `requested` are the icon hashes this very message asked for and the
// cache still lacks: only a notification waiting on one of them is held.
nonisolated struct MirrorPlan: Equatable, Sendable {
    var diff: StateSyncDiff
    var actions: [MirrorAction]

    static func sync(
        _ activeSet: [NotificationInfo], shown: [String: MirrorEntry], hold: IconHold, requested: Set<String>,
        interacted: InteractedMemory = InteractedMemory(), now: ContinuousClock.Instant = .now
    ) -> MirrorPlan {
        let diff = StateSyncDiff.compute(mirror: hold.overlaid(on: shown), activeSet: activeSet)
        var actions: [MirrorAction] = []
        for hash in diff.removed {
            if hold[hash] != nil { actions.append(.cancel(keyHash: hash)) }
            if shown[hash] != nil { actions.append(.remove(keyHash: hash)) }
        }
        for info in diff.added + diff.updated.map(\.new) + diff.untouched.map(\.info) {
            if let action = step(info, shown: shown, hold: hold, requested: requested, interacted: interacted, now: now) {
                actions.append(action)
            }
        }
        return MirrorPlan(diff: diff, actions: actions)
    }

    static func upsert(
        _ info: NotificationInfo, shown: [String: MirrorEntry], hold: IconHold, requested: Set<String>,
        interacted: InteractedMemory = InteractedMemory(), now: ContinuousClock.Instant = .now
    ) -> MirrorPlan {
        let keyHash = Signal.keyHash(of: info.key)
        var actions = MirrorAction.posting(hold.all.filter { $0.keyHash != keyHash })
        if let action = step(info, shown: shown, hold: hold, requested: requested, interacted: interacted, now: now) {
            actions.append(action)
        }
        return MirrorPlan(diff: StateSyncDiff.upsert(info, mirror: hold.overlaid(on: shown)), actions: actions)
    }

    // A held notification still on the phone goes out now with its newest content, or stays held if
    // that content waits on an icon this message asked for; it never alerts less than it would have.
    // A new one alerts unless InteractedMemory makes its re-add quiet.
    private static func step(
        _ info: NotificationInfo, shown: [String: MirrorEntry], hold: IconHold, requested: Set<String>,
        interacted: InteractedMemory, now: ContinuousClock.Instant
    ) -> MirrorAction? {
        let keyHash = Signal.keyHash(of: info.key)
        let alerting: Bool
        if let held = hold[keyHash] {
            alerting = held.alerting || MirrorRendering.replacementAlerts(old: held.info, new: info)
        } else if let old = shown[keyHash] {
            guard RenderedContent(old.info) != RenderedContent(info) else { return nil }
            alerting = MirrorRendering.replacementAlerts(old: old.info, new: info)
        } else {
            alerting = !interacted.readdIsQuiet(info, at: now)
        }
        if let iconHash = info.iconHash, requested.contains(iconHash) {
            return .hold(info, alerting: alerting)
        }
        return .post(info, alerting: alerting)
    }
}
