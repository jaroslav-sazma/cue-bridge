import Foundation

// Spec, frame types: a reply goes inline while its whole plaintext fits one frame (159 bytes of
// UTF-8 JSON), otherwise as a `reply` frame with the tcp flag followed by `reply-text`.
nonisolated enum ReplyEncoding: Equatable, Sendable {
    case inline(Signal)
    case overTcp(Signal, BridgeMessage)

    static func plan(key: String, text: String) throws -> ReplyEncoding {
        let keyHash = Signal.keyHash(of: key)
        let inline = Signal.reply(keyHash: keyHash, text: text)
        if try inline.plaintext().count <= SignalFrame.maxPlaintextBytes { return .inline(inline) }
        return .overTcp(.replyOverTcp(keyHash: keyHash), .replyText(key: key, text: text))
    }

    // Nil for a reply that is nothing but whitespace: it is not sent.
    static func trimmed(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// The replies sent, by key hash, with what the mirror showed, each waiting for the phone's answer —
// reply-ok or reply-error — until its deadline. Memory only; a record leaves with its answer, at its
// deadline, or as the oldest once the cap is passed. A second reply to the same notification takes
// the place of the first, so one answer settles the key.
nonisolated struct PendingReplies: Equatable, Sendable {
    static let capacity = 16
    static let answerDeadline = Duration.seconds(30)

    struct Record: Equatable, Sendable {
        var appLabel: String
        var title: String
    }

    private struct Waiting: Equatable, Sendable {
        var record: Record
        var due: ContinuousClock.Instant
    }

    private var waiting: [String: Waiting] = [:]
    private var order: [String] = []

    var count: Int { order.count }

    var nextDeadline: ContinuousClock.Instant? { waiting.values.map(\.due).min() }

    mutating func record(_ keyHash: String, _ record: Record, at now: ContinuousClock.Instant = .now) {
        take(keyHash)
        waiting[keyHash] = Waiting(record: record, due: now + Self.answerDeadline)
        order.append(keyHash)
        while order.count > Self.capacity {
            waiting[order.removeFirst()] = nil
        }
    }

    @discardableResult
    mutating func take(_ keyHash: String) -> Record? {
        guard let entry = waiting.removeValue(forKey: keyHash) else { return nil }
        order.removeAll { $0 == keyHash }
        return entry.record
    }

    // The replies whose answer is overdue at `now`, oldest first; they are no longer waited for.
    mutating func overdue(at now: ContinuousClock.Instant) -> [(keyHash: String, record: Record)] {
        let late = order.filter { waiting[$0].map { now >= $0.due } ?? false }
        return late.compactMap { keyHash in take(keyHash).map { (keyHash, $0) } }
    }

    mutating func forgetAll() {
        waiting = [:]
        order = []
    }
}

nonisolated struct LocalNoticeText: Equatable, Sendable {
    var title: String
    var subtitle: String
    var body: String
}

// The Mac's own notifications: a reply that failed, the flash after a tap on a mirror, and the
// notice for a text the user sent from the phone. None of them ever carries clipboard text.
nonisolated enum LocalNotices {
    static let clipboardArrived = LocalNoticeText(
        title: "Sent from your phone", subtitle: "", body: "Press ⌘V to paste it."
    )

    enum ReplyFailure: Equatable, Sendable {
        case notConnected
        // The Mac could not read the mirror or seal the frame: nothing reached the phone.
        case notSent
        case phone(reason: String?)
        // Neither reply-ok nor reply-error came in time: the reply may or may not have arrived.
        case unconfirmed
    }

    static func replyFailed(_ record: PendingReplies.Record?, _ failure: ReplyFailure) -> LocalNoticeText {
        let body = switch failure {
        case .notConnected: "Your phone is not connected, so the reply was not sent."
        case .notSent: "This Mac could not send the reply."
        case .phone("gone"): "The notification is no longer on your phone."
        case .phone("no-reply-action"): "The notification no longer accepts a reply."
        case .phone: "Your phone could not deliver the reply."
        case .unconfirmed: "Your phone did not confirm the reply, so it may not have been sent."
        }
        let subtitle = record.map { $0.title.isEmpty ? $0.appLabel : "\($0.appLabel) — \($0.title)" } ?? ""
        let title = failure == .unconfirmed ? "Reply not confirmed" : "Reply failed"
        return LocalNoticeText(title: title, subtitle: subtitle, body: body)
    }

    static func openOnPhone(appLabel: String?) -> LocalNoticeText {
        LocalNoticeText(
            title: appLabel.map { "Can't open \($0) here" } ?? "Can't open the app here",
            subtitle: "", body: "Continue on your phone."
        )
    }
}
