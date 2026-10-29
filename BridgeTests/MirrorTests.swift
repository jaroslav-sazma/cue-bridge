import CryptoKit
import Foundation
import Testing

private func info(
    key: String = "0|com.example.chat|42|null|10123", title: String = "Alice", text: String = "Hi",
    threadId: String? = "com.example.chat/alice", iconHash: String? = nil, canReply: Bool = true
) -> NotificationInfo {
    NotificationInfo(
        key: key, pkg: "com.example.chat", appLabel: "Example Chat", title: title, text: text, when: 1_791_820_800_000,
        threadId: threadId, canReply: canReply, isClearable: true, iconHash: iconHash
    )
}

private let hash1 = String(repeating: "a", count: 64)
private let hash2 = String(repeating: "b", count: 64)

@Suite("Mirror rendering")
struct MirrorRenderingTests {
    @Test("the title joins the app label and the title, or is the app label alone")
    func title() {
        #expect(MirrorRendering.title(info(title: "Alice")) == "Example Chat — Alice")
        #expect(MirrorRendering.title(info(title: "")) == "Example Chat")
    }

    @Test("the thread is the threadId, else the package")
    func thread() {
        #expect(MirrorRendering.threadIdentifier(info(threadId: "t")) == "t")
        #expect(MirrorRendering.threadIdentifier(info(threadId: nil)) == "com.example.chat")
        #expect(MirrorRendering.threadIdentifier(info(threadId: "")) == "com.example.chat")
    }

    @Test("only a change of the visible text alerts again")
    func alerts() {
        let old = info()
        #expect(MirrorRendering.replacementAlerts(old: old, new: info(text: "New")))
        #expect(MirrorRendering.replacementAlerts(old: old, new: info(title: "Bob")))
        #expect(!MirrorRendering.replacementAlerts(old: old, new: info(iconHash: hash1)))
        #expect(!MirrorRendering.replacementAlerts(old: old, new: info(threadId: "other")))
        #expect(!MirrorRendering.replacementAlerts(old: old, new: info(canReply: false)))
    }
}

@Suite("Mirror table")
struct MirrorTableTests {
    @Test("userInfo round-trips every field, and a foreign request is not a mirror")
    func userInfo() {
        for entry in [
            MirrorEntry(info: info(iconHash: hash1), hasIcon: true),
            MirrorEntry(info: info(threadId: nil, iconHash: nil), hasIcon: false),
        ] {
            let bridged = (entry.userInfo as NSDictionary) as! [AnyHashable: Any]
            #expect(MirrorEntry(userInfo: bridged) == entry)
        }
        #expect(MirrorEntry(userInfo: [:]) == nil)
        var wrongFormat = MirrorEntry(info: info(), hasIcon: false).userInfo
        wrongFormat[MirrorEntry.marker] = 2
        #expect(MirrorEntry(userInfo: wrongFormat) == nil)
    }

    @Test("a just-posted request overrides a lagging or stale delivered list long past 10 s")
    func recentPostsUnseen() {
        let start = ContinuousClock.now
        var recent = RecentPosts()
        let fresh = MirrorEntry(info: info(text: "New"), hasIcon: false)
        let stale = MirrorEntry(info: info(text: "Old"), hasIcon: false)
        recent.record(fresh, at: start)

        let lagging = recent.merged(over: [:], at: start + .seconds(2))
        #expect(lagging == RecentPosts.Merge(table: [fresh.keyHash: fresh]), "lagging add")
        let overriding = recent.merged(over: [stale.keyHash: stale], at: start + .seconds(15))
        #expect(overriding == RecentPosts.Merge(table: [fresh.keyHash: fresh]), "a stale copy is no sighting")
        let late = recent.merged(over: [:], at: start + .seconds(59))
        #expect(late.table == [fresh.keyHash: fresh], "unseen, so still overlaid near the cap")
        #expect(recent.keyHashes == [fresh.keyHash])
    }

    @Test("a post leaves the overlay once a read has seen exactly it delivered")
    func recentPostsSeen() {
        let start = ContinuousClock.now
        var recent = RecentPosts()
        let fresh = MirrorEntry(info: info(text: "New"), hasIcon: false)
        recent.record(fresh, at: start)

        let sighting = recent.merged(over: [fresh.keyHash: fresh], at: start + .seconds(1))
        #expect(sighting == RecentPosts.Merge(table: [fresh.keyHash: fresh], seen: [fresh.keyHash]))
        #expect(recent.keyHashes.isEmpty)
        let gone = recent.merged(over: [:], at: start + .seconds(2))
        #expect(gone == RecentPosts.Merge(table: [:]), "after the sighting the delivered list decides")
    }

    @Test("an unseen post leaves the overlay at the 60 s cap, and a removal forgets it at once")
    func recentPostsCapAndForget() {
        let start = ContinuousClock.now
        var recent = RecentPosts()
        let fresh = MirrorEntry(info: info(text: "New"), hasIcon: false)
        recent.record(fresh, at: start)
        let capped = recent.merged(over: [:], at: start + RecentPosts.cap)
        #expect(RecentPosts.cap == .seconds(60))
        #expect(capped == RecentPosts.Merge(table: [:], expired: [fresh.keyHash]))
        #expect(recent.keyHashes.isEmpty)

        recent.record(fresh, at: start)
        recent.forget(fresh.keyHash)
        let forgotten = recent.merged(over: [:], at: start)
        #expect(forgotten == RecentPosts.Merge(table: [:]))
    }

    @Test("a tombstone lives at least five seconds and then goes")
    func tombstones() {
        let start = ContinuousClock.now
        var tombstones = Tombstones()
        tombstones.insert("0123456789abcdef", at: start)
        let live = tombstones.contains("0123456789abcdef", at: start + .seconds(5))
        let other = tombstones.contains("fedcba9876543210", at: start)
        let gone = tombstones.contains("0123456789abcdef", at: start + Tombstones.lifetime)
        #expect(Tombstones.lifetime >= .seconds(5))
        #expect(live && !other && !gone)
    }

    @Test("a standalone notif-detail is an add, an update or nothing")
    func upsert() {
        let entry = MirrorEntry(info: info(), hasIcon: true)
        let mirror = [entry.keyHash: entry]
        #expect(StateSyncDiff.upsert(info(key: "other"), mirror: mirror).added.map(\.key) == ["other"])
        #expect(StateSyncDiff.upsert(info(text: "New"), mirror: mirror).updated.map(\.new.text) == ["New"])
        let same = StateSyncDiff.upsert(info(), mirror: mirror)
        #expect(same.untouched == [entry] && same.added.isEmpty && same.updated.isEmpty && same.removed.isEmpty)
    }
}

@Suite("Icon hold")
struct IconHoldTests {
    private let chat = info(iconHash: hash1)
    private let mail = info(key: "0|com.example.mail|7|null|10123", title: "Bob", iconHash: hash2)

    private func held(_ notifications: [NotificationInfo]) -> IconHold {
        var hold = IconHold()
        for notification in notifications {
            hold.hold(notification, alerting: true)
        }
        return hold
    }

    @Test("a new notification is held only for an icon this very message asked for")
    func holdRule() {
        let asked = MirrorPlan.sync([chat], shown: [:], hold: IconHold(), requested: [hash1])
        #expect(asked.actions == [.hold(chat, alerting: true)])
        #expect(asked.diff.added == [chat])
        let askedBefore = MirrorPlan.sync([chat], shown: [:], hold: IconHold(), requested: [])
        #expect(askedBefore.actions == [.post(chat, alerting: true)])
        let noIcon = info(iconHash: nil)
        let none = MirrorPlan.sync([noIcon], shown: [:], hold: IconHold(), requested: [hash1])
        #expect(none.actions == [.post(noIcon, alerting: true)])
        let detail = MirrorPlan.upsert(chat, shown: [:], hold: IconHold(), requested: [hash1])
        #expect(detail.actions == [.hold(chat, alerting: true)])
    }

    @Test("a held notification counts as mirrored and is posted once by the next active-set")
    func nextActiveSet() {
        let hold = held([chat])
        let table = hold.overlaid(on: [:])
        #expect(table == [Signal.keyHash(of: chat.key): MirrorEntry(info: chat, hasIcon: false, pending: true)])

        let same = MirrorPlan.sync([chat], shown: [:], hold: hold, requested: [])
        #expect(same.diff.added.isEmpty && same.diff.untouched.count == 1)
        #expect(same.actions == [.post(chat, alerting: true)])

        let newer = info(text: "Newer", iconHash: hash1)
        let changed = MirrorPlan.sync([newer], shown: [:], hold: hold, requested: [])
        #expect(changed.diff.updated.count == 1)
        #expect(changed.actions == [.post(newer, alerting: true)], "posted once, with the newest content")

        let otherIcon = info(text: "Newer", iconHash: hash2)
        let rehold = MirrorPlan.sync([otherIcon], shown: [:], hold: hold, requested: [hash2])
        #expect(rehold.actions == [.hold(otherIcon, alerting: true)])
    }

    @Test("a held notification gone from the set is cancelled, and removed too if an older copy shows")
    func goneFromSet() {
        let shownMail = MirrorEntry(info: info(key: mail.key, title: "Bob", text: "Old"), hasIcon: false)
        let hold = held([chat, mail])
        let shown = [shownMail.keyHash: shownMail]
        let plan = MirrorPlan.sync([], shown: shown, hold: hold, requested: [])
        let chatHash = Signal.keyHash(of: chat.key)
        let mailHash = Signal.keyHash(of: mail.key)
        #expect(Set(plan.diff.removed) == [chatHash, mailHash])
        #expect(plan.actions.contains(.cancel(keyHash: chatHash)))
        #expect(!plan.actions.contains(.remove(keyHash: chatHash)))
        #expect(plan.actions.contains(.cancel(keyHash: mailHash)))
        #expect(plan.actions.contains(.remove(keyHash: mailHash)))
    }

    @Test("an update waiting on a new icon is held and keeps the alert its text change earned")
    func heldUpdate() {
        let old = MirrorEntry(info: info(text: "Old"), hasIcon: false)
        let shown = [old.keyHash: old]
        let quiet = MirrorPlan.sync([info(text: "Old", iconHash: hash1)], shown: shown, hold: IconHold(), requested: [hash1])
        #expect(quiet.actions == [.hold(info(text: "Old", iconHash: hash1), alerting: false)])
        let loud = MirrorPlan.sync([chat], shown: shown, hold: IconHold(), requested: [hash1])
        #expect(loud.actions == [.hold(chat, alerting: true)])
        let untouched = MirrorPlan.sync([old.info], shown: shown, hold: IconHold(), requested: [hash1])
        #expect(untouched.actions.isEmpty)
    }

    @Test("a notif-detail posts the other held notifications as they are")
    func detail() {
        let hold = held([chat, mail])
        let newer = info(key: mail.key, title: "Bob", text: "Again", iconHash: hash2)
        let plan = MirrorPlan.upsert(newer, shown: [:], hold: hold, requested: [])
        #expect(plan.actions == [.post(chat, alerting: true), .post(newer, alerting: true)])
    }

    @Test("an icon releases only the notifications waiting for it; release all empties the hold")
    func release() {
        var hold = held([chat, mail, info(key: "2", iconHash: hash1)])
        let released = hold.release(iconHash: hash1)
        #expect(Set(released.map(\.info.key)) == [chat.key, "2"])
        #expect(hold.all.map(\.info) == [mail])
        let again = hold.release(iconHash: hash1)
        #expect(again.isEmpty)
        let rest = hold.releaseAll()
        #expect(rest.map(\.info) == [mail])
        #expect(hold.isEmpty)
    }

    @Test("applying a plan holds, and a post or a cancel takes the notification out")
    func apply() {
        var hold = IconHold()
        hold.apply([.hold(chat, alerting: true), .hold(mail, alerting: false)])
        #expect(hold[Signal.keyHash(of: mail.key)] == IconHold.Held(info: mail, alerting: false))
        hold.apply([.post(chat, alerting: true), .cancel(keyHash: Signal.keyHash(of: mail.key))])
        #expect(hold.isEmpty)
    }

    @Test("an update held for its icon and cancelled by a dismiss is not posted when the icon comes")
    func dismissCancelsHold() {
        var hold = held([chat])
        let cancelled = hold.cancel(Signal.keyHash(of: chat.key))
        #expect(cancelled == IconHold.Held(info: chat, alerting: true))
        let released = hold.release(iconHash: hash1)
        #expect(released.isEmpty)
        let plan = MirrorPlan.sync([chat], shown: [:], hold: hold, requested: [])
        #expect(plan.diff.added == [chat], "only a new active-set listing it brings it back")
    }
}

@Suite("Icons")
struct IconTests {
    @Test("an icon verifies only against the SHA-256 of its bytes in lowercase hex")
    func verify() {
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let hash = Data(SHA256.hash(data: png)).hex
        #expect(IconHash.of(png) == hash)
        #expect(IconHash.verifies(hash, png))
        #expect(!IconHash.verifies(hash.uppercased(), png))
        #expect(!IconHash.verifies(hash, png + Data([0])))
        #expect(!IconHash.isWellFormed("../" + String(hash.dropFirst(3))))
    }

    @Test("each missing hash is asked for once per connection, cached and malformed ones never")
    func requests() {
        var requests = IconRequests()
        let cached = String(repeating: "c", count: 64)
        let notifications = [
            info(iconHash: hash1), info(key: "2", iconHash: hash1), info(key: "3", iconHash: cached),
            info(key: "4", iconHash: "not-a-hash"), info(key: "5", iconHash: nil), info(key: "6", iconHash: hash2),
        ]
        let first = requests.toRequest(notifications, isCached: { $0 == cached })
        let again = requests.toRequest(notifications, isCached: { $0 == cached })
        #expect(first == [hash1, hash2])
        #expect(again.isEmpty)
        #expect(requests.wasRequested(hash1) && requests.wasRequested(hash2))
        #expect(!requests.wasRequested(cached))
    }
}
