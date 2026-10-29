import Foundation
import UserNotifications
import os

nonisolated enum MirrorOutbound: Sendable {
    case dismiss(keyHash: String, revision: Int64?)
    case reply(key: String, text: String)
}

nonisolated enum OutboundResult: Sendable {
    case sent
    case noSession
    // The signal could not be sealed or its sequence number saved.
    case notSent
}

// The mirror is Notification Center itself: every command reads the delivered requests back (plus
// what the Mac posted and has not yet seen delivered, see RecentPosts, and what waits for its icon,
// see IconHold), so the table survives the app being killed. Commands run strictly one after
// another in submission order, each to its end. Every read also diffs the table against the last
// one, which is how a dismissal without a callback is caught (DismissalBook); what vanished is
// judged by a command of its own, behind whatever was queued meanwhile.
actor NotificationMirror {
    nonisolated static let category = "cue-mirror"
    nonisolated static let replyCategory = "cue-mirror-reply"
    nonisolated static let replyAction = "cue.reply"
    // The Mac's own notifications. Their identifiers contain a dot, so they never equal a key hash,
    // and their categories are not the mirror's, so no read, judgment or response takes them for one.
    nonisolated static let flashCategory = "cue-flash"
    nonisolated static let setClickAction = "cue.set-click-action"
    nonisolated static let replyFailedCategory = "cue-reply-failed"
    nonisolated static let clipboardCategory = "cue-clipboard"
    nonisolated static let flashIdentifier = "cue.flash"
    nonisolated static let clipboardIdentifier = "cue.clipboard"
    nonisolated static let flashLifetime = Duration.seconds(10)

    struct Report: Sendable {
        var mirrored: Int
        var sync: BridgeStatus.StateSync?
        var resetsSync = false
    }

    enum Response: Sendable {
        case dismissed
        case opened
        case replied(text: String)
        case other(String)
    }

    // `requested` carries the icon hashes the same message asked the phone for.
    enum Command: Sendable {
        case load
        case sync([NotificationInfo], requested: Set<String>)
        case upsert(NotificationInfo, requested: Set<String>)
        case remove(keyHash: String)
        case iconArrived(hash: String)
        case iconFailed(hash: String)
        // Submitted with a session's first active-set, so dismissals are judged against a phone
        // whose ledger is filled.
        case sessionStarted
        case sessionEnded
        // A GATT subscription confirmed as the paired phone's: a dismissal can reach it without a
        // session, and the phone resolves the key hash through its shade.
        case bluetooth(linked: Bool)
        case removeAll
        case response(keyHash: String, entry: MirrorEntry?, Response)
        case replyFailed(keyHash: String, reason: String?)
        // Internal: a click action that found nothing to open; the reminder stands in for it.
        case clickFailed(keyHash: String, entry: MirrorEntry, ClickAction.Kind)
        // Internal: a click action that opened something; the phone's copy is closed as well.
        case clickOpened(keyHash: String, entry: MirrorEntry)
        case replyConfirmed(keyHash: String)
        // Internal: the earliest answer a reply waits for is overdue.
        case replyDeadline
        case reconcile(ReconcilePass)
        case clipboardArrived
        // Internal: what a read found gone, judged once the commands queued behind that read ran.
        case vanished([MirrorEntry], origin: String)
        case table(CheckedContinuation<[MirrorEntry], Never>)
    }

    private let center = UNUserNotificationCenter.current()
    private let icons: IconCache
    private let clicks: ClickStore
    private let communication = CommunicationStyle()
    private let report: @Sendable (Report) -> Void
    private let outbound: @Sendable (MirrorOutbound) async -> OutboundResult
    private let commands: AsyncStream<Command>.Continuation
    private let log = Logger(subsystem: "app.cue.bridge", category: "mirror")
    private var recent = RecentPosts()
    private var book = DismissalBook()
    private var interacted = InteractedMemory()
    private var replies = PendingReplies()
    private var hold = IconHold()
    // Re-adds a state-sync held back until the judgment of their vanished mirror.
    private var heldForJudgment: [String: NotificationInfo] = [:]
    private var sessionUp = false
    private var bluetoothUp = false
    private var removals: [String: Task<Void, Never>] = [:]
    private var replyDeadline: Task<Void, Never>?

    init(
        icons: IconCache, clicks: ClickStore, report: @escaping @Sendable (Report) -> Void,
        outbound: @escaping @Sendable (MirrorOutbound) async -> OutboundResult
    ) {
        self.icons = icons
        self.clicks = clicks
        self.report = report
        self.outbound = outbound
        let (stream, continuation) = AsyncStream.makeStream(of: Command.self)
        commands = continuation
        Task {
            for await command in stream {
                await self.run(command)
            }
        }
        continuation.yield(.load)
    }

    nonisolated static func isMirror(_ categoryIdentifier: String) -> Bool {
        categoryIdentifier == category || categoryIdentifier == replyCategory
    }

    nonisolated static func categoryDefinitions() -> Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(
            identifier: replyAction, title: "Reply", options: [], textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply on your phone"
        )
        let setClick = UNNotificationAction(identifier: setClickAction, title: "Set Click Action…", options: [.foreground])
        return [
            UNNotificationCategory(identifier: category, actions: [], intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(
                identifier: replyCategory, actions: [reply], intentIdentifiers: [], options: [.customDismissAction]
            ),
            UNNotificationCategory(identifier: flashCategory, actions: [setClick], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: replyFailedCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: clipboardCategory, actions: [], intentIdentifiers: [], options: []),
        ]
    }

    nonisolated func submit(_ command: Command) {
        commands.yield(command)
    }

    nonisolated func entries() async -> [MirrorEntry] {
        await withCheckedContinuation { submit(.table($0)) }
    }

    private func run(_ command: Command) async {
        switch command {
        case .load:
            report(Report(mirrored: await shown("load").count))
        case .sync(let notifications, let requested):
            await sync(notifications, requested: requested)
        case .upsert(let info, let requested):
            await upsert(info, requested: requested)
        case .remove(let keyHash):
            await removeOne(keyHash)
        case .iconArrived(let hash):
            let released = hold.release(iconHash: hash)
            log.debug("icon \(String(hash.prefix(16)), privacy: .public) cached, \(released.count) held posted with it")
            await release(released)
        case .iconFailed(let hash):
            let released = hold.release(iconHash: hash)
            log.debug("icon \(String(hash.prefix(16)), privacy: .public) failed, \(released.count) held posted without it")
            await release(released)
        case .sessionStarted:
            sessionUp = true
            log.debug("session synced, dismissals are judged")
        case .sessionEnded:
            sessionUp = false
            let released = hold.releaseAll()
            if !released.isEmpty { log.debug("session ended, \(released.count) held posted without their icon") }
            await release(released)
        case .bluetooth(let linked):
            bluetoothUp = linked
            log.debug("bluetooth link to the phone \(linked ? "confirmed" : "down", privacy: .public), dismissals \(linked || self.sessionUp ? "are" : "are not", privacy: .public) judged")
        case .removeAll:
            await removeAll()
        case .response(let keyHash, let entry, let response):
            await respond(keyHash, entry, response)
        case .replyFailed(let keyHash, let reason):
            await replyFailed(keyHash, reason: reason)
        case .clickFailed(let keyHash, let entry, let kind):
            log.info("mirror k=\(keyHash, privacy: .public) click action \(kind.rawValue, privacy: .public) had nothing to open, reminder shown, kept on the phone")
            await remind(entry)
        case .clickOpened(let keyHash, let entry):
            let verdict = book.judgeOpened(entry, interacted: interacted, at: .now)
            // A state-sync during the click may have added the same copy back passively; the phone
            // sends no removal for what it cancels on a dismiss, so it goes here.
            if verdict == .send { center.removeDeliveredNotifications(withIdentifiers: [keyHash]) }
            await carryOut(verdict, keyHash, source: "click")
            report(Report(mirrored: hold.overlaid(on: await shown("click")).count))
        case .replyConfirmed(let keyHash):
            replyConfirmed(keyHash)
        case .replyDeadline:
            await repliesOverdue()
        case .reconcile(let pass):
            await reconcile(pass)
        case .clipboardArrived:
            await transient(
                LocalNotices.clipboardArrived, identifier: Self.clipboardIdentifier, category: Self.clipboardCategory,
                name: "clipboard notice"
            )
        case .vanished(let entries, let origin):
            await judgeVanished(entries, origin: origin)
        case .table(let continuation):
            let entries = hold.overlaid(on: await shown("table")).values.sorted {
                ($0.info.when, $0.keyHash) < ($1.info.when, $1.keyHash)
            }
            continuation.resume(returning: entries)
        }
    }

    private func shown(_ origin: String) async -> [String: MirrorEntry] {
        await read(origin).table
    }

    // A mirror that left the table since the last read without being removed, tapped or replied to
    // here was dismissed by the user — ✕ or Clear All whose callback did not come, or came later.
    // macOS removes a tapped or replied mirror before it delivers the response, so what vanished is
    // only collected here and judged by a `.vanished` command queued behind the response.
    private func read(_ origin: String) async -> (table: [String: MirrorEntry], delivered: Int, vanished: [MirrorEntry]) {
        var delivered: [String: MirrorEntry] = [:]
        for notification in await center.deliveredNotifications()
        where Self.isMirror(notification.request.content.categoryIdentifier) {
            if let entry = MirrorEntry(userInfo: notification.request.content.userInfo) {
                delivered[notification.request.identifier] = entry
            }
        }
        let merge = recent.merged(over: delivered, at: .now)
        for hash in merge.seen {
            log.debug("mirror k=\(hash, privacy: .public) seen delivered")
        }
        for hash in merge.expired {
            log.info("mirror k=\(hash, privacy: .public) not seen delivered within \(RecentPosts.cap.components.seconds) s, the delivered list decides")
        }
        guard await centerKeepsMirrors() else {
            book.forgetBaseline()
            log.debug("\(origin, privacy: .public): notifications off or kept out of Notification Center, no dismissal check")
            return (merge.table, delivered.count, [])
        }
        guard sessionUp || bluetoothUp else {
            book.extend(with: merge.table)
            return (merge.table, delivered.count, [])
        }
        let vanished = book.settle(on: merge.table)
        if !vanished.isEmpty { submit(.vanished(vanished, origin: origin)) }
        return (merge.table, delivered.count, vanished)
    }

    // Revoked authorization or "Show in Notification Center" turned off empties the delivered list,
    // which would read as every mirror dismissed at once.
    private func centerKeepsMirrors() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return settings.notificationCenterSetting == .enabled
        default:
            return false
        }
    }

    private func reconcile(_ pass: ReconcilePass) async {
        let (table, delivered, vanished) = await read("reconcile \(pass.rawValue)")
        if !vanished.isEmpty {
            log.info("reconcile \(pass.rawValue, privacy: .public): delivered \(delivered), mirrored \(table.count), vanished \(vanished.count)")
        } else {
            log.debug("reconcile \(pass.rawValue, privacy: .public): delivered \(delivered), mirrored \(table.count), nothing vanished")
        }
        report(Report(mirrored: hold.overlaid(on: table).count))
    }

    // Runs behind every command queued after the read, so a response delivered meanwhile has set
    // its tombstone and its interaction first.
    // A re-add a state-sync held back for this judgment is restored, passively, unless the mirror
    // turns out to have been dismissed.
    private func judgeVanished(_ entries: [MirrorEntry], origin: String) async {
        let held = hold.all.count
        var restore: [MirrorAction] = []
        for entry in entries {
            let verdict = book.judgeVanished(entry, interacted: interacted, at: .now)
            await carryOut(verdict, entry.keyHash, source: origin)
            if let info = heldForJudgment.removeValue(forKey: entry.keyHash), verdict == .notADismissal || verdict == .superseded {
                restore.append(.post(info, alerting: false))
            }
        }
        if !restore.isEmpty {
            log.debug("\(restore.count) held back from the state-sync restored: not dismissed")
            interacted.settle(after: restore)
            _ = await execute(restore, on: await shown("restore"))
        }
        if hold.all.count != held || !restore.isEmpty {
            report(Report(mirrored: hold.overlaid(on: await shown("vanished")).count))
        }
    }

    // Two kinds of closing on the Mac reach this set before the phone has acted on them: a pending
    // dismissal, sent or not, and one the read just found gone — Clear All without callbacks while
    // the phone was away. Neither is added back; the first is dismissed again now, the second once
    // its judgment, queued behind this sync, has run.
    private func sync(_ notifications: [NotificationInfo], requested: Set<String>) async {
        await clicks.saw(notifications.map(PhoneApp.init))
        let (before, _, vanished) = await read("state-sync")
        let settlement = book.settle(notifications, at: .now)
        let split = DismissalBook.holdingBack(settlement.kept, vanished: vanished)
        for info in split.held {
            heldForJudgment[Signal.keyHash(of: info.key)] = info
        }
        let incoming = split.kept
        if incoming.count < notifications.count {
            log.debug("state-sync: \(notifications.count - incoming.count) dismissed here, not added again")
        }
        let plan = MirrorPlan.sync(
            incoming, shown: before, hold: hold, requested: uncached(requested), interacted: interacted, now: .now
        )
        interacted.settle(after: plan.actions)
        interacted.retain(Set(notifications.map { Signal.keyHash(of: $0.key) }))
        let after = await execute(plan.actions, on: before)
        let diff = plan.diff
        log.info(
            "state-sync applied: added \(diff.added.count), updated \(diff.updated.count), removed \(diff.removed.count), untouched \(diff.untouched.count)"
        )
        for due in settlement.due {
            await sendDismiss(due.keyHash, revision: due.revision, source: "pending")
        }
        report(Report(
            mirrored: hold.overlaid(on: after).count,
            sync: .init(
                count: diff.added.count + diff.updated.count + diff.untouched.count, added: diff.added.count,
                updated: diff.updated.count, removed: diff.removed.count, untouched: diff.untouched.count, at: .now
            )
        ))
    }

    private func upsert(_ info: NotificationInfo, requested: Set<String>) async {
        await clicks.saw([PhoneApp(info)])
        let before = await shown("notif-detail")
        let keyHash = Signal.keyHash(of: info.key)
        if let due = book.settle(detail: info, at: .now).due.first {
            log.debug("mirror k=\(keyHash, privacy: .public) dismissed here, not added again")
            report(Report(mirrored: hold.overlaid(on: before).count))
            await sendDismiss(due.keyHash, revision: due.revision, source: "pending")
            return
        }
        let plan = MirrorPlan.upsert(
            info, shown: before, hold: hold, requested: uncached(requested), interacted: interacted, now: .now
        )
        interacted.settle(after: plan.actions)
        if plan.diff.untouched.count == 1, hold[keyHash] == nil {
            log.debug("mirror k=\(keyHash, privacy: .public) unchanged")
        }
        let after = await execute(plan.actions, on: before)
        report(Report(mirrored: hold.overlaid(on: after).count))
    }

    private func removeOne(_ keyHash: String) async {
        var table = await shown("notif-removed")
        if hold.cancel(keyHash) != nil {
            log.debug("mirror hold k=\(keyHash, privacy: .public) cancelled")
        } else if table[keyHash] == nil {
            log.debug("mirror k=\(keyHash, privacy: .public) not mirrored, removed anyway")
        }
        interacted.forget(keyHash)
        remove([keyHash])
        table[keyHash] = nil
        report(Report(mirrored: hold.overlaid(on: table).count))
    }

    private func release(_ released: [IconHold.Held]) async {
        guard !released.isEmpty else { return }
        let after = await execute(MirrorAction.posting(released), on: await shown("icon"))
        report(Report(mirrored: hold.overlaid(on: after).count))
    }

    // The book is reset first, so the tombstones of this very removal survive it.
    private func removeAll() async {
        let hashes = Set(await shown("unpair").keys).union(recent.keyHashes)
        let held = hold.releaseAll().count
        book.forgetAll()
        heldForJudgment = [:]
        interacted.forgetAll()
        replies.forgetAll()
        armReplyDeadline()
        remove(hashes.sorted())
        recent.forgetAll()
        icons.wipe()
        removals[Self.flashIdentifier]?.cancel()
        removals[Self.flashIdentifier] = nil
        center.removeDeliveredNotifications(withIdentifiers: [Self.flashIdentifier])
        await clicks.forgetSeen()
        await communication.forgetDonations()
        log.info("all \(hashes.count) mirrors removed, \(held) held dropped")
        report(Report(mirrored: 0, resetsSync: true))
    }

    private func uncached(_ hashes: Set<String>) -> Set<String> {
        hashes.filter { !icons.contains($0) }
    }

    // The hold is updated first; a post that fails afterwards leaves its notification unmirrored,
    // and the next state-sync adds it again.
    private func execute(_ actions: [MirrorAction], on shown: [String: MirrorEntry]) async -> [String: MirrorEntry] {
        var shown = shown
        hold.apply(actions)
        var allowed: Bool?
        for action in actions {
            switch action {
            case .remove(let keyHash):
                remove([keyHash])
                shown[keyHash] = nil
            case .cancel(let keyHash):
                log.debug("mirror hold k=\(keyHash, privacy: .public) cancelled")
            case .hold(let info, _):
                log.debug(
                    "mirror hold k=\(Signal.keyHash(of: info.key), privacy: .public) icon=\(String((info.iconHash ?? "").prefix(16)), privacy: .public)"
                )
            case .post(let info, let alerting):
                if allowed == nil { allowed = await authorized() }
                if allowed == true, let entry = await post(info, alerting: alerting) { shown[entry.keyHash] = entry }
            }
        }
        return shown
    }

    // MARK: Responses

    // A tap and a reply both take the mirror out of Notification Center, and neither is a dismissal
    // by itself: the phone keeps a replied notification and one whose click shows the reminder. A
    // click action closes the phone's copy only once macOS reports it opened (`.clickOpened`).
    private func respond(_ keyHash: String, _ entry: MirrorEntry?, _ response: Response) async {
        switch response {
        case .dismissed:
            let verdict = book.judge(
                keyHash, content: entry.map { AlertContent($0.info) }, revision: entry?.info.revision, at: .now
            )
            await carryOut(verdict, keyHash, source: "callback")
        case .opened:
            setAside(keyHash)
            if let entry { interacted.recordTap(entry.info) }
            log.info("mirror k=\(keyHash, privacy: .public) opened here")
            await opened(keyHash, entry)
        case .replied(let text):
            setAside(keyHash)
            interacted.recordReply(keyHash, at: .now)
            await reply(keyHash, entry, text)
        case .other(let action):
            log.info("mirror response action=\(action, privacy: .public) k=\(keyHash, privacy: .public) ignored")
        }
        report(Report(mirrored: hold.overlaid(on: await shown("response")).count))
    }

    // The action runs on the main actor, off this loop: a cold app launch or a Gatekeeper prompt
    // would hold up every command behind it. The outcome comes back as a command of its own.
    private func opened(_ keyHash: String, _ entry: MirrorEntry?) async {
        guard let entry, let action = await clicks.action(for: entry.info.pkg) else {
            log.info("mirror k=\(keyHash, privacy: .public) reminder shown, kept on the phone")
            await remind(entry)
            return
        }
        log.info("mirror k=\(keyHash, privacy: .public) click action \(action.kind.rawValue, privacy: .public) handed to macOS")
        log.debug("mirror k=\(keyHash, privacy: .public) pkg=\(entry.info.pkg, privacy: .private) click action \(String(describing: action), privacy: .private)")
        Task { @MainActor in
            let opened = await ClickLauncher.perform(action)
            self.submit(opened ? .clickOpened(keyHash: keyHash, entry: entry) : .clickFailed(keyHash: keyHash, entry: entry, action.kind))
        }
    }

    private func remind(_ entry: MirrorEntry?) async {
        await transient(
            LocalNotices.openOnPhone(appLabel: entry?.info.appLabel), identifier: Self.flashIdentifier,
            category: Self.flashCategory, name: "flash", userInfo: entry.map { PhoneApp($0.info).userInfo } ?? [:]
        )
    }

    private func setAside(_ keyHash: String) {
        book.setAside(keyHash, at: .now)
        recent.forget(keyHash)
    }

    // A dismiss sent also cancels an update held for its icon, which would otherwise bring back what
    // the user closed.
    private func carryOut(_ verdict: DismissVerdict, _ keyHash: String, source: String) async {
        switch verdict {
        case .notADismissal:
            log.debug("mirror k=\(keyHash, privacy: .public) gone (\(source, privacy: .public)): removed, opened or replied here, no dismiss")
        case .alreadyPending:
            log.debug("mirror k=\(keyHash, privacy: .public) gone (\(source, privacy: .public)): dismiss already pending")
        case .superseded:
            log.info("mirror k=\(keyHash, privacy: .public) gone (\(source, privacy: .public)): posted again with new text since, no dismiss")
        case .send:
            recent.forget(keyHash)
            interacted.forget(keyHash)
            if hold.cancel(keyHash) != nil {
                log.debug("mirror hold k=\(keyHash, privacy: .public) cancelled: dismissed here")
            }
            await sendDismiss(keyHash, revision: book.pending(keyHash)?.revision, source: source)
        }
    }

    // Whatever happens to the frame, the dismissal stays pending until a state-sync settles it.
    private func sendDismiss(_ keyHash: String, revision: Int64?, source: String) async {
        let r = revision.map(String.init) ?? "-"
        switch await outbound(.dismiss(keyHash: keyHash, revision: revision)) {
        case .sent:
            log.info("dismiss k=\(keyHash, privacy: .public) r=\(r, privacy: .public) sent (\(source, privacy: .public)), pending until a state-sync settles it")
        case .noSession:
            log.info("dismiss k=\(keyHash, privacy: .public) r=\(r, privacy: .public) pending for the next state-sync (\(source, privacy: .public)): no session or Bluetooth link, \(self.book.pendingCount) pending")
        case .notSent:
            log.error("dismiss k=\(keyHash, privacy: .public) not sent (\(source, privacy: .public)): the signal could not be sealed, pending for the next state-sync")
        }
    }

    // A reply that does not reach the phone forgets its interaction, so the next re-add alerts.
    private func reply(_ keyHash: String, _ entry: MirrorEntry?, _ text: String) async {
        guard let entry else {
            interacted.forget(keyHash)
            log.error("reply k=\(keyHash, privacy: .public) has no mirror record, not sent")
            await noticeReplyFailed(keyHash, nil, .notSent)
            return
        }
        guard let text = ReplyEncoding.trimmed(text) else {
            // Nothing went to the phone, so no update answers it: the re-add is a tap's.
            interacted.recordTap(entry.info)
            log.info("reply k=\(keyHash, privacy: .public) is empty, not sent")
            return
        }
        let record = PendingReplies.Record(appLabel: entry.info.appLabel, title: entry.info.title)
        replies.record(keyHash, record)
        log.debug("reply k=\(keyHash, privacy: .public) text=\(text, privacy: .private) bytes=\(text.utf8.count)")
        switch await outbound(.reply(key: entry.info.key, text: text)) {
        case .sent:
            armReplyDeadline()
            log.info("reply k=\(keyHash, privacy: .public) sent, waiting \(PendingReplies.answerDeadline.components.seconds) s for its answer")
        case .noSession:
            replies.take(keyHash)
            interacted.forget(keyHash)
            log.info("reply k=\(keyHash, privacy: .public) not sent: no session or Bluetooth link")
            await noticeReplyFailed(keyHash, record, .notConnected)
        case .notSent:
            replies.take(keyHash)
            interacted.forget(keyHash)
            log.error("reply k=\(keyHash, privacy: .public) not sent: the frame could not be sealed")
            await noticeReplyFailed(keyHash, record, .notSent)
        }
    }

    private func replyFailed(_ keyHash: String, reason: String?) async {
        interacted.forget(keyHash)
        let record = replies.take(keyHash)
        armReplyDeadline()
        log.info(
            "reply-error k=\(keyHash, privacy: .public) reason=\(String((reason ?? "-").prefix(32)), privacy: .private) matched=\(record != nil)"
        )
        await noticeReplyFailed(keyHash, record, .phone(reason: reason))
    }

    private func replyConfirmed(_ keyHash: String) {
        let matched = replies.take(keyHash) != nil
        armReplyDeadline()
        log.info("reply-ok k=\(keyHash, privacy: .public) matched=\(matched)")
    }

    // An answer that comes after this finds no record and is only logged.
    private func repliesOverdue() async {
        for (keyHash, record) in replies.overdue(at: .now) {
            interacted.forget(keyHash)
            log.info("reply k=\(keyHash, privacy: .public) unanswered after \(PendingReplies.answerDeadline.components.seconds) s")
            await noticeReplyFailed(keyHash, record, .unconfirmed)
        }
        armReplyDeadline()
    }

    // The one timer of the replies, armed only while one waits for its answer.
    private func armReplyDeadline() {
        replyDeadline?.cancel()
        replyDeadline = nil
        guard let due = replies.nextDeadline else { return }
        replyDeadline = Task {
            try? await Task.sleep(until: due, tolerance: .seconds(1), clock: .continuous)
            guard !Task.isCancelled else { return }
            self.submit(.replyDeadline)
        }
    }

    private func noticeReplyFailed(
        _ keyHash: String, _ record: PendingReplies.Record?, _ failure: LocalNotices.ReplyFailure
    ) async {
        _ = await notice(
            LocalNotices.replyFailed(record, failure), identifier: "cue.reply-failed.\(keyHash)",
            category: Self.replyFailedCategory, sound: true
        )
    }

    // The sanctioned one-shot removal of a transient notice (the tap flash, the clipboard notice),
    // one per identifier; a new notice under the same identifier restarts it.
    private func transient(
        _ text: LocalNoticeText, identifier: String, category: String, name: String, userInfo: [String: Any] = [:]
    ) async {
        guard await notice(text, identifier: identifier, category: category, sound: false, userInfo: userInfo) else {
            return
        }
        removals[identifier]?.cancel()
        removals[identifier] = Task {
            try? await Task.sleep(for: Self.flashLifetime, tolerance: .seconds(5), clock: .continuous)
            guard !Task.isCancelled else { return }
            self.center.removeDeliveredNotifications(withIdentifiers: [identifier])
            self.log.debug("\(name, privacy: .public) removed")
        }
        log.debug("\(name, privacy: .public) shown, removed in \(Self.flashLifetime.components.seconds) s")
    }

    private func notice(
        _ text: LocalNoticeText, identifier: String, category: String, sound: Bool, userInfo: [String: Any] = [:]
    ) async -> Bool {
        guard await authorized() else { return false }
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.categoryIdentifier = category
        content.interruptionLevel = .active
        content.sound = sound ? .default : nil
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        } catch {
            log.error("\(category, privacy: .public) notice failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: Posting

    private func remove(_ hashes: [String]) {
        guard !hashes.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: hashes)
        let now = ContinuousClock.now
        for hash in hashes {
            recent.forget(hash)
            book.setAside(hash, at: now)
            log.debug("mirror remove k=\(hash, privacy: .public)")
        }
    }

    // A passive replacement is added to the list without a banner or a sound; it is how a change
    // that leaves the visible text alone is applied without alerting a second time.
    private func post(_ info: NotificationInfo, alerting: Bool) async -> MirrorEntry? {
        let keyHash = Signal.keyHash(of: info.key)
        let content = UNMutableNotificationContent()
        content.title = MirrorRendering.title(info)
        content.body = info.text
        content.threadIdentifier = MirrorRendering.threadIdentifier(info)
        content.categoryIdentifier = info.canReply ? Self.replyCategory : Self.category
        content.interruptionLevel = alerting ? .active : .passive
        content.sound = alerting ? .default : nil
        // The userInfo goes in before the content is styled, which returns a copy not to be mutated.
        var styled: UNNotificationContent?
        if let plan = communication.plan(info, icons: icons) {
            content.userInfo = MirrorEntry(info: info, hasIcon: true).userInfo
            styled = await communication.styled(content, plan, keyHash: keyHash)
        }
        var copy: URL?
        if MirrorIconPlacement.choose(styled: styled != nil) == .attachment, let hash = info.iconHash,
           let url = icons.attachmentCopy(hash) {
            do {
                content.attachments = [try UNNotificationAttachment(identifier: "icon", url: url)]
                copy = url
            } catch {
                try? FileManager.default.removeItem(at: url)
                log.info("icon \(String(hash.prefix(16)), privacy: .public) not attachable: \(error.localizedDescription, privacy: .public)")
            }
        }
        let entry = MirrorEntry(info: info, hasIcon: styled != nil || !content.attachments.isEmpty)
        content.userInfo = entry.userInfo
        do {
            try await center.add(UNNotificationRequest(identifier: keyHash, content: styled ?? content, trigger: nil))
        } catch {
            if let copy { try? FileManager.default.removeItem(at: copy) }
            log.error("mirror post k=\(keyHash, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        recent.record(entry, at: .now)
        book.posted(keyHash, content: AlertContent(info))
        interacted.posted(keyHash)
        log.debug(
            "mirror post k=\(keyHash, privacy: .public) alerting=\(alerting) icon=\(entry.hasIcon) avatar=\(styled != nil) title=\(content.title, privacy: .private)"
        )
        return entry
    }

    // The first request can fail although the user allows notifications, so the status is read once
    // more after a failure, and the next command asks again.
    private func authorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .denied:
            log.info("notifications are not allowed for Cue:; mirrors are not shown")
            return false
        default:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                log.info("notification authorization requested, granted=\(granted)")
                return granted
            } catch {
                let status = await center.notificationSettings().authorizationStatus
                log.info(
                    "notification authorization request failed: \(error.localizedDescription, privacy: .public); status now \(status.rawValue)"
                )
                return status == .authorized || status == .provisional
            }
        }
    }
}
