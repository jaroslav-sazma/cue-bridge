import Foundation
import Testing

private func info(
    key: String = "0|com.example.chat|42|null|10123", title: String = "Alice", text: String = "Hi", revision: Int64? = nil
) -> NotificationInfo {
    NotificationInfo(
        key: key, pkg: "com.example.chat", appLabel: "Example Chat", title: title, text: text, when: 1_791_820_800_000,
        threadId: nil, canReply: true, isClearable: true, iconHash: nil, revision: revision
    )
}

private func entry(_ info: NotificationInfo) -> MirrorEntry {
    MirrorEntry(info: info, hasIcon: false)
}

private func table(_ infos: NotificationInfo...) -> [String: MirrorEntry] {
    Dictionary(uniqueKeysWithValues: infos.map { (Signal.keyHash(of: $0.key), entry($0)) })
}

private let chat = info()
private let mail = info(key: "0|com.example.mail|7|null|10123", title: "Bob")
private let chatHash = Signal.keyHash(of: chat.key)
private let mailHash = Signal.keyHash(of: mail.key)

// #expect cannot take a mutating call, so each step binds its result first.
@Suite("Dismissal book")
struct DismissalBookTests {
    @Test("a mirror missing from the next read is a dismissal, sent once")
    func missingIsDismissed() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        let first = book.settle(on: table(chat, mail))
        let vanished = book.settle(on: table(mail))
        #expect(first.isEmpty)
        #expect(vanished.map(\.keyHash) == [chatHash])
        let verdict = book.judge(chatHash, content: AlertContent(chat), at: now)
        let callbackLater = book.judge(chatHash, content: AlertContent(chat), at: now + .milliseconds(5))
        #expect(verdict == .send)
        #expect(callbackLater == .alreadyPending, "the delegate callback after the pass sends nothing more")
        let after = book.settle(on: table(mail))
        #expect(after.isEmpty)
    }

    @Test("a fresh post lagging the delivered list is not read as missing until seen or capped")
    func freshPostOverride() {
        let start = ContinuousClock.now
        var recent = RecentPosts()
        var book = DismissalBook()
        recent.record(entry(chat), at: start)
        let posted = book.settle(on: recent.merged(over: [:], at: start).table)
        let lagging = book.settle(on: recent.merged(over: [:], at: start + .seconds(16)).table)
        let late = book.settle(on: recent.merged(over: [:], at: start + RecentPosts.cap).table)
        #expect(posted.isEmpty && lagging.isEmpty, "unseen, so overlaid well past the old 10 s")
        #expect(late.map(\.keyHash) == [chatHash], "never seen delivered by the cap")
    }

    @Test("once seen delivered, a post that then goes missing is read as vanished")
    func seenThenMissing() {
        let start = ContinuousClock.now
        var recent = RecentPosts()
        var book = DismissalBook()
        recent.record(entry(chat), at: start)
        let seen = book.settle(on: recent.merged(over: table(chat), at: start + .seconds(1)).table)
        let missing = book.settle(on: recent.merged(over: [:], at: start + .seconds(2)).table)
        #expect(seen.isEmpty)
        #expect(missing.map(\.keyHash) == [chatHash])
    }

    @Test("a response handled before the deferred judgment keeps a vanished mirror from a dismiss")
    func deferredJudgment() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        var memory = InteractedMemory()
        _ = book.settle(on: table(chat, mail))
        let vanished = book.settle(on: [:])
        #expect(vanished.map(\.keyHash) == [chatHash, mailHash], "macOS removed both before any response")
        book.setAside(chatHash, at: now)
        memory.recordTap(chat)
        let tapped = book.judgeVanished(entry(chat), interacted: memory, at: now + .milliseconds(5))
        let dismissed = book.judgeVanished(entry(mail), interacted: memory, at: now + .milliseconds(5))
        #expect(tapped == .notADismissal)
        #expect(dismissed == .send)
    }

    @Test("a tapped or replied copy is never a dismissal, even past its tombstone")
    func interactedNeverDismissed() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        var memory = InteractedMemory()
        memory.recordTap(chat)
        memory.recordReply(mailHash, at: now)
        let late = now + Tombstones.lifetime + .seconds(60)
        let tap = book.judgeVanished(entry(chat), interacted: memory, at: late)
        let reply = book.judgeVanished(entry(mail), interacted: memory, at: late)
        let readded = book.settle([chat, mail], at: late)
        #expect(tap == .notADismissal && reply == .notADismissal)
        #expect(readded.kept == [chat, mail] && readded.due.isEmpty, "nothing recorded as pending")
    }

    @Test("a copy posted after the tap is judged like any other once it vanishes")
    func repostedAfterTap() {
        var book = DismissalBook()
        var memory = InteractedMemory()
        memory.recordTap(chat)
        let plan = MirrorPlan.sync([chat], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        memory.settle(after: plan.actions)
        memory.posted(chatHash)
        book.posted(chatHash, content: AlertContent(chat))
        #expect(memory.readdIsQuiet(chat, at: .now), "the tap still quiets an unchanged re-add")
        let verdict = book.judgeVanished(entry(chat), interacted: memory, at: .now)
        #expect(verdict == .send, "Clear All on the re-added copy syncs")
    }

    @Test("a click action that opened something closes the tapped copy on the phone, once")
    func openedClosesOnPhone() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        var memory = InteractedMemory()
        let tapped = info(revision: 3)
        _ = book.settle(on: table(tapped, mail))
        book.setAside(chatHash, at: now)
        memory.recordTap(tapped)
        let vanished = book.judgeVanished(entry(tapped), interacted: memory, at: now + .milliseconds(5))
        let opened = book.judgeOpened(entry(tapped), interacted: memory, at: now + .milliseconds(100))
        memory.forget(chatHash)
        let again = book.judgeOpened(entry(tapped), interacted: memory, at: now + .milliseconds(200))
        #expect(vanished == .notADismissal, "the tap alone never dismisses")
        #expect(opened == .send, "the tap's live tombstone gives way to the opened click")
        #expect(again == .notADismissal, "the send forgot the tap")
        #expect(book.pending(chatHash)?.revision == 3)
        let listed = book.settle([tapped], at: now + .seconds(1))
        #expect(listed.due.map(\.keyHash) == [chatHash] && listed.kept.isEmpty, "not added back, sent again")
    }

    @Test("an open that outlasts the tap's tombstone still closes the phone's copy")
    func openedSlowly() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        var memory = InteractedMemory()
        book.setAside(chatHash, at: now)
        memory.recordTap(chat)
        let opened = book.judgeOpened(entry(chat), interacted: memory, at: now + Tombstones.lifetime + .seconds(20))
        #expect(opened == .send)
    }

    @Test("a click that opened something closes a same-text re-add, not a copy with new text")
    func openedAfterRepost() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        var memory = InteractedMemory()
        book.posted(chatHash, content: AlertContent(chat))
        book.posted(mailHash, content: AlertContent(mail))
        book.setAside(chatHash, at: now)
        book.setAside(mailHash, at: now)
        memory.recordTap(chat)
        memory.recordTap(mail)
        let newMail = info(key: mail.key, title: "Bob", text: "Are you coming?")
        let plan = MirrorPlan.sync([chat, newMail], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        memory.settle(after: plan.actions)
        book.posted(chatHash, content: AlertContent(chat))
        memory.posted(chatHash)
        book.posted(mailHash, content: AlertContent(newMail))
        let same = book.judgeOpened(entry(chat), interacted: memory, at: now + .milliseconds(10))
        let newer = book.judgeOpened(entry(mail), interacted: memory, at: now + .milliseconds(10))
        #expect(same == .send, "the passive re-add of the clicked copy goes with it")
        #expect(newer == .notADismissal, "the new message alerted, which ends the tap; it stays on the phone")
        #expect(book.pending(mailHash) == nil)
        memory.recordTap(mail)
        let passive = book.judgeOpened(entry(mail), interacted: memory, at: now + .milliseconds(20))
        #expect(passive == .superseded, "other text posted since the click is never closed by it")
    }

    @Test("a click that opened something after its tap was forgotten sends nothing")
    func openedForgotten() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        var memory = InteractedMemory()
        book.setAside(chatHash, at: now)
        memory.recordTap(chat)
        memory.forget(chatHash)
        let removed = book.judgeOpened(entry(chat), interacted: memory, at: now + .milliseconds(10))
        let unpaired = book.judgeOpened(entry(mail), interacted: InteractedMemory(), at: now + .milliseconds(10))
        #expect(removed == .notADismissal, "the phone removed the key during the click")
        #expect(unpaired == .notADismissal)
        #expect(book.pendingCount == 0)
    }

    @Test("re-posted before the judgment: the same text is still dismissed, new text is not")
    func repostedBeforeJudgment() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        book.posted(chatHash, content: AlertContent(chat))
        book.posted(mailHash, content: AlertContent(mail))
        _ = book.settle(on: table(chat, mail))
        let vanished = book.settle(on: [:])
        #expect(vanished.count == 2, "Clear All while the phone was away")
        book.posted(chatHash, content: AlertContent(chat))
        let newMail = info(key: mail.key, title: "Bob", text: "Are you coming?")
        book.posted(mailHash, content: AlertContent(newMail))
        let same = book.judgeVanished(entry(chat), interacted: InteractedMemory(), at: now)
        let newer = book.judgeVanished(entry(mail), interacted: InteractedMemory(), at: now)
        #expect(same == .send, "the reconnect re-add is taken back with the dismissal")
        #expect(newer == .superseded, "a new message the user has not closed stays on the phone")
    }

    @Test("without a session a read only extends the baseline, so the first read with one judges")
    func noSessionCarries() {
        var book = DismissalBook()
        _ = book.settle(on: table(chat, mail))
        book.extend(with: table(mail))
        book.extend(with: [:])
        #expect(Set(book.expected.keys) == [chatHash, mailHash], "nothing judged, nothing dropped")
        let other = info(key: "0|com.example.chat|43|null|10123", title: "Carol")
        book.extend(with: table(mail, other))
        let reconnected = book.settle(on: table(mail))
        #expect(reconnected.map(\.keyHash).sorted() == [chatHash, Signal.keyHash(of: other.key)].sorted())
    }

    @Test("with Notification Center unavailable the baseline is dropped, not read as all dismissed")
    func baselineForgotten() {
        var book = DismissalBook()
        _ = book.settle(on: table(chat, mail))
        book.forgetBaseline()
        let shownAgain = book.settle(on: [:])
        #expect(shownAgain.isEmpty)
    }

    @Test("what the Mac removed, and what was tapped or replied to, is never a dismissal")
    func setAside() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        _ = book.settle(on: table(chat, mail))
        book.setAside(chatHash, at: now)
        let vanished = book.settle(on: table(mail))
        #expect(vanished.isEmpty, "set aside leaves the baseline at once")

        _ = book.settle(on: table(chat, mail))
        let lagged = book.settle(on: table(mail))
        let verdict = book.judge(chatHash, content: nil, at: now + .seconds(1))
        #expect(lagged.map(\.keyHash) == [chatHash], "a removal that lags the delivered list")
        #expect(verdict == .notADismissal)
        let expired = book.judge(chatHash, content: nil, at: now + Tombstones.lifetime)
        #expect(expired == .send)
    }

    @Test("a dismiss callback sends even for a mirror the last read did not know")
    func callbackAlone() {
        var book = DismissalBook()
        let verdict = book.judge(chatHash, content: nil, at: .now)
        #expect(verdict == .send)
    }

    @Test("a new post supersedes a tombstone and a pending dismissal")
    func repost() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        book.setAside(chatHash, at: now)
        book.posted(chatHash, content: AlertContent(chat))
        let afterTap = book.judge(chatHash, content: nil, at: now + .seconds(1))
        #expect(afterTap == .send, "a passive re-add closed with ✕ still syncs")
        book.posted(chatHash, content: AlertContent(chat))
        let again = book.judge(chatHash, content: nil, at: now + .seconds(2))
        #expect(again == .send)
    }

    @Test("a just-dismissed key is not added back by an active-set, however late, unless it changed")
    func notAddedBack() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        _ = book.judge(chatHash, content: AlertContent(chat), at: now)
        let same = book.settle([chat, mail], at: now + .seconds(60))
        #expect(same.kept == [mail])
        #expect(same.due == [.init(keyHash: chatHash, revision: nil)], "no echo window: still due a minute later")
        let changed = info(text: "Are you there?")
        let newer = book.settle([changed], at: now + .seconds(61))
        #expect(newer.kept == [changed] && newer.due.isEmpty, "new content is a new notification for the user")
        #expect(book.pendingCount == 0)
    }

    @Test("a dismissal whose content is unknown holds back whatever the phone lists under the key")
    func unknownContentHeld() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        _ = book.judge(chatHash, content: nil, at: now)
        let held = book.settle([info(text: "Other")], at: now)
        #expect(held.kept.isEmpty && held.due.map(\.keyHash) == [chatHash])
    }

    @Test("forgetting all clears the baseline, the tombstones and the pending dismissals")
    func forgetAll() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        _ = book.settle(on: table(chat))
        book.setAside(mailHash, at: now)
        _ = book.judge(chatHash, content: nil, at: now)
        book.forgetAll()
        #expect(book.expected.isEmpty)
        let mailVerdict = book.judge(mailHash, content: nil, at: now)
        #expect(mailVerdict == .send)
    }
}

@Suite("Pending dismissals")
struct PendingDismissalTests {
    private let r1: Int64 = 1_791_820_800_000
    private let r2: Int64 = 1_791_820_860_000

    // A dismissal judged and sent, or not: either way it is pending.
    private func dismissing(_ info: NotificationInfo, at now: ContinuousClock.Instant, in book: inout DismissalBook) {
        let verdict = book.judge(
            Signal.keyHash(of: info.key), content: AlertContent(info), revision: info.revision, at: now
        )
        #expect(verdict == .send)
    }

    @Test("a dismissal stays pending through every set that still lists it, hours later too")
    func dueUntilGone() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        let closed = info(revision: r1)
        dismissing(closed, at: now, in: &book)
        let later = now + .seconds(3 * 60 * 60)
        let first = book.settle([closed, mail], at: later)
        let second = book.settle([closed, mail], at: later + .seconds(5))
        #expect(first.due == [.init(keyHash: chatHash, revision: r1)])
        #expect(first.kept == [mail], "what the user closed is not added back")
        #expect(second == first, "a dismiss that got lost is sent again")
        let settled = book.settle([mail], at: later + .seconds(10))
        #expect(settled.due.isEmpty && book.pendingCount == 0)
    }

    @Test("a newer post with the same content is dismissed again at its revision; new content comes back")
    func revisions() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(info(revision: r1), at: now, in: &book)
        let reposted = info(revision: r2)
        let same = book.settle([reposted], at: now + .seconds(1))
        #expect(same.due == [.init(keyHash: chatHash, revision: r2)] && same.kept.isEmpty)
        #expect(book.pending(chatHash)?.revision == r2, "the next dismiss goes at the new revision")
        let newer = info(text: "Are you there?", revision: r2 + 1)
        let changed = book.settle([newer], at: now + .seconds(2))
        #expect(changed.due.isEmpty && changed.kept == [newer])
        #expect(book.pendingCount == 0)
    }

    @Test("the revision decides over the content, which decides only without one")
    func revisionWins() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(info(revision: r1), at: now, in: &book)
        let sameRevision = book.settle([info(text: "Edited", revision: r1)], at: now)
        #expect(sameRevision.due.map(\.keyHash) == [chatHash], "the phone still shows the copy the user closed")
        var plain = DismissalBook()
        dismissing(chat, at: now, in: &plain)
        let unrevised = plain.settle([chat], at: now)
        #expect(unrevised.due == [.init(keyHash: chatHash, revision: nil)])
    }

    @Test("a detail of a pending key is decided like a set's entry but never settles it")
    func detail() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(info(revision: r1), at: now, in: &book)
        let same = book.settle(detail: info(revision: r2), at: now)
        #expect(same.due == [.init(keyHash: chatHash, revision: r2)] && same.kept.isEmpty)
        let other = book.settle(detail: mail, at: now)
        #expect(other.kept == [mail] && book.pendingCount == 1)
        let newer = info(text: "Are you there?", revision: r2 + 1)
        let changed = book.settle(detail: newer, at: now)
        #expect(changed.kept == [newer] && book.pendingCount == 0)
    }

    @Test("a phone set that brings new content cancels the pending dismissal and the copy comes back")
    func supersededByNewContent() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(chat, at: now, in: &book)
        let newer = info(text: "Are you there?")
        let settlement = book.settle([newer], at: now + .seconds(60))
        #expect(settlement.due.isEmpty)
        #expect(settlement.kept == [newer])
    }

    @Test("a key the phone no longer lists has nothing left to close")
    func goneFromPhone() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(chat, at: now, in: &book)
        let settlement = book.settle([mail], at: now + .seconds(60))
        #expect(settlement.due.isEmpty)
        #expect(book.pendingCount == 0)
    }

    @Test("a callback for a pending key sends nothing more")
    func pendingIsNotSentTwice() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(chat, at: now, in: &book)
        let again = book.judge(chatHash, content: AlertContent(chat), at: now + .seconds(30))
        #expect(again == .alreadyPending)
    }

    @Test("a new post or a removal on the phone's behalf settles what was pending")
    func settledByPostOrRemoval() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(chat, at: now, in: &book)
        dismissing(mail, at: now, in: &book)
        book.posted(chatHash, content: AlertContent(chat))
        book.setAside(mailHash, at: now)
        #expect(book.pendingCount == 0)
        let settlement = book.settle([chat, mail], at: now + .seconds(60))
        #expect(settlement.due.isEmpty)
    }

    @Test("a pending dismissal expires after a day, and past the cap the oldest goes")
    func lifetimeAndCap() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(chat, at: now, in: &book)
        let expired = book.settle([chat], at: now + DismissalBook.pendingLifetime)
        #expect(expired.due.isEmpty && expired.kept == [chat])

        var capped = DismissalBook()
        let many = (0...DismissalBook.pendingCapacity).map { info(key: "0|com.example.chat|\($0)|null|10123") }
        for (index, item) in many.enumerated() {
            dismissing(item, at: now + .milliseconds(index), in: &capped)
        }
        #expect(capped.pendingCount == DismissalBook.pendingCapacity)
        let settlement = capped.settle(many, at: now + .seconds(1))
        #expect(!settlement.due.map(\.keyHash).contains(Signal.keyHash(of: many[0].key)), "the oldest went past the cap")
        #expect(settlement.due.count == DismissalBook.pendingCapacity)
    }

    @Test("forgetting all drops what was pending")
    func forgetAll() {
        let now = ContinuousClock.now
        var book = DismissalBook()
        dismissing(chat, at: now, in: &book)
        book.forgetAll()
        #expect(book.pendingCount == 0)
    }

    @Test("a state-sync holds back the re-add of what its read found gone, unless the content changed")
    func holdingBack() {
        let newMail = info(key: mail.key, title: "Bob", text: "Are you coming?")
        let other = info(key: "0|com.example.chat|43|null|10123", title: "Carol")
        let split = DismissalBook.holdingBack([chat, newMail, other], vanished: [entry(chat), entry(mail)])
        #expect(split.held == [chat])
        #expect(split.kept == [newMail, other])
        let none = DismissalBook.holdingBack([chat], vanished: [])
        #expect(none.kept == [chat] && none.held.isEmpty)
    }
}

@Suite("Interacted memory")
struct InteractedMemoryTests {
    @Test("a tapped notification back unchanged is re-added passively")
    func unchangedIsPassive() {
        var memory = InteractedMemory()
        memory.recordTap(chat)
        let plan = MirrorPlan.sync([chat], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        #expect(plan.actions == [.post(chat, alerting: false)])
        #expect(plan.diff.added == [chat])
        memory.settle(after: plan.actions)
        #expect(memory.contains(chatHash))
    }

    @Test("a change of the visible text alerts and ends the memory")
    func changedAlerts() {
        var memory = InteractedMemory()
        memory.recordTap(chat)
        let changed = info(text: "Are you there?")
        let plan = MirrorPlan.sync([changed], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        #expect(plan.actions == [.post(changed, alerting: true)])
        memory.settle(after: plan.actions)
        #expect(!memory.contains(chatHash))
    }

    @Test("a re-add that waits on its icon is held passive as well")
    func held() {
        var memory = InteractedMemory()
        memory.recordTap(chat)
        let withIcon = NotificationInfo(
            key: chat.key, pkg: chat.pkg, appLabel: chat.appLabel, title: chat.title, text: chat.text, when: chat.when,
            threadId: nil, canReply: true, isClearable: true, iconHash: String(repeating: "a", count: 64)
        )
        let plan = MirrorPlan.upsert(withIcon, shown: [:], hold: IconHold(), requested: [withIcon.iconHash!], interacted: memory)
        #expect(plan.actions == [.hold(withIcon, alerting: false)])
    }

    @Test("only the visible text counts, not the thread, icon or reply ability")
    func alertFields() {
        var memory = InteractedMemory()
        memory.recordTap(chat)
        let quiet = NotificationInfo(
            key: chat.key, pkg: chat.pkg, appLabel: chat.appLabel, title: chat.title, text: chat.text, when: 1,
            threadId: "other", canReply: false, isClearable: true, iconHash: String(repeating: "b", count: 64)
        )
        #expect(memory.readdIsQuiet(quiet, at: .now))
        #expect(!memory.readdIsQuiet(info(title: "Bob"), at: .now))
        #expect(!memory.readdIsQuiet(mail, at: .now))
    }

    @Test("a removal on the phone, a dismissal or an active-set without the key clears it")
    func cleared() {
        var memory = InteractedMemory()
        memory.recordTap(chat)
        memory.recordTap(mail)
        memory.forget(chatHash)
        #expect(!memory.contains(chatHash) && memory.contains(mailHash))
        memory.recordTap(chat)
        memory.retain([chatHash])
        #expect(memory.contains(chatHash) && !memory.contains(mailHash))
        #expect(memory.count == 1)
    }

    @Test("past the cap the oldest key goes, and a repeat refreshes its place")
    func cap() {
        var memory = InteractedMemory()
        let first = info(key: "key-0")
        for index in 0..<InteractedMemory.capacity {
            memory.recordTap(info(key: "key-\(index)"))
        }
        memory.recordTap(first)
        memory.recordTap(info(key: "key-new"))
        #expect(memory.count == InteractedMemory.capacity)
        #expect(memory.contains(Signal.keyHash(of: first.key)), "refreshed, so not the oldest")
        #expect(!memory.contains(Signal.keyHash(of: "key-1")), "the oldest after the refresh")
        #expect(memory.contains(Signal.keyHash(of: "key-new")))
    }

    @Test("the first re-add after a reply is passive although the app changed the content")
    func replyChangedIsPassive() {
        var memory = InteractedMemory()
        memory.recordReply(chatHash, at: .now)
        let answered = info(text: "You: On my way")
        let plan = MirrorPlan.sync([answered], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        #expect(plan.actions == [.post(answered, alerting: false)])
    }

    @Test("a reply quiets only the first re-add: the next change alerts again")
    func replyIsUsedOnce() {
        var memory = InteractedMemory()
        memory.recordReply(chatHash, at: .now)
        let answered = info(text: "You: On my way")
        let first = MirrorPlan.sync([answered], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        memory.settle(after: first.actions)
        #expect(!memory.contains(chatHash), "consumed by the passive re-add itself")
        let next = info(text: "Great, see you")
        let second = MirrorPlan.sync([next], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        #expect(second.actions == [.post(next, alerting: true)])
        let replacement = MirrorPlan.upsert(next, shown: table(answered), hold: IconHold(), requested: [], interacted: memory)
        #expect(replacement.actions == [.post(next, alerting: true)], "the usual replacement once it is back")
    }

    @Test("a reply followed by unchanged content is re-added passively and used up as well")
    func replyUnchangedIsConsumed() {
        var memory = InteractedMemory()
        memory.recordReply(chatHash, at: .now)
        let plan = MirrorPlan.upsert(chat, shown: [:], hold: IconHold(), requested: [], interacted: memory)
        #expect(plan.actions == [.post(chat, alerting: false)])
        memory.settle(after: plan.actions)
        #expect(!memory.contains(chatHash))
    }

    @Test("a tap outlives its passive re-add, a reply does not")
    func tapIsNotUsedUp() {
        var memory = InteractedMemory()
        memory.recordTap(chat)
        memory.recordReply(mailHash, at: .now)
        let plan = MirrorPlan.sync([chat, mail], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        #expect(plan.actions.count == 2)
        #expect(plan.actions.contains(.post(chat, alerting: false)) && plan.actions.contains(.post(mail, alerting: false)))
        memory.settle(after: plan.actions)
        #expect(memory.contains(chatHash) && !memory.contains(mailHash))
    }

    @Test("a replied re-add held for its icon is used up by the hold and released passive")
    func replyHeld() {
        var memory = InteractedMemory()
        memory.recordReply(chatHash, at: .now)
        let iconHash = String(repeating: "c", count: 64)
        let answered = NotificationInfo(
            key: chat.key, pkg: chat.pkg, appLabel: chat.appLabel, title: chat.title, text: "You: On my way",
            when: chat.when, threadId: nil, canReply: true, isClearable: true, iconHash: iconHash
        )
        var hold = IconHold()
        let plan = MirrorPlan.upsert(answered, shown: [:], hold: hold, requested: [iconHash], interacted: memory)
        #expect(plan.actions == [.hold(answered, alerting: false)])
        memory.settle(after: plan.actions)
        #expect(!memory.contains(chatHash), "consumed when the plan is made, not on release")
        hold.apply(plan.actions)
        let released = MirrorAction.posting(hold.release(iconHash: iconHash))
        #expect(released == [.post(answered, alerting: false)])
    }

    @Test("a removal, a dismissal, an active-set without the key or an unpair clears a reply")
    func replyCleared() {
        var memory = InteractedMemory()
        memory.recordReply(chatHash, at: .now)
        memory.forget(chatHash)
        #expect(!memory.contains(chatHash))
        memory.recordReply(chatHash, at: .now)
        memory.retain([mailHash])
        #expect(!memory.contains(chatHash))
        memory.recordReply(chatHash, at: .now)
        memory.forgetAll()
        #expect(memory.count == 0)
        let plan = MirrorPlan.sync([info(text: "Later")], shown: [:], hold: IconHold(), requested: [], interacted: memory)
        #expect(plan.actions == [.post(info(text: "Later"), alerting: true)])
    }

    @Test("a reply quiets a re-add only within 30 s of it; later the re-add alerts")
    func replyWindow() {
        let replied = ContinuousClock.now
        var memory = InteractedMemory()
        memory.recordReply(chatHash, at: replied)
        let answered = info(text: "You: On my way")
        let inside = MirrorPlan.sync(
            [answered], shown: [:], hold: IconHold(), requested: [], interacted: memory, now: replied + .seconds(29)
        )
        let after = MirrorPlan.upsert(
            answered, shown: [:], hold: IconHold(), requested: [], interacted: memory,
            now: replied + InteractedMemory.replyQuiet
        )
        #expect(InteractedMemory.replyQuiet == .seconds(30))
        #expect(inside.actions == [.post(answered, alerting: false)])
        #expect(after.actions == [.post(answered, alerting: true)])
        memory.settle(after: after.actions)
        #expect(!memory.contains(chatHash), "the alerting re-add ends it")
    }

    @Test("a failed reply is forgotten, so the next re-add alerts")
    func failedReplyAlerts() {
        let replied = ContinuousClock.now
        var memory = InteractedMemory()
        memory.recordReply(chatHash, at: replied)
        memory.forget(chatHash)
        let plan = MirrorPlan.sync(
            [chat], shown: [:], hold: IconHold(), requested: [], interacted: memory, now: replied + .seconds(1)
        )
        var book = DismissalBook()
        let verdict = book.judgeVanished(entry(chat), interacted: memory, at: replied + .seconds(1))
        #expect(plan.actions == [.post(chat, alerting: true)])
        #expect(verdict == .send, "and its vanished copy is no longer covered")
    }

    @Test("an empty memory changes nothing: a new notification alerts")
    func empty() {
        let plan = MirrorPlan.sync([chat], shown: [:], hold: IconHold(), requested: [], interacted: InteractedMemory())
        #expect(plan.actions == [.post(chat, alerting: true)])
    }
}
