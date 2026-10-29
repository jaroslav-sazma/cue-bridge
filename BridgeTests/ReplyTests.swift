import Foundation
import Testing

private let key = "0|com.example.chat|42|null|10123"

// The inline plaintext is {"k":"<16 hex>","t":"<text>"}: 31 bytes around the text's JSON form.
private let overhead = 31

@Suite("Reply encoding")
struct ReplyEncodingTests {
    private func plan(_ text: String) throws -> ReplyEncoding {
        try ReplyEncoding.plan(key: key, text: text)
    }

    private func inlineBytes(_ text: String) throws -> Int {
        try Signal.reply(keyHash: Signal.keyHash(of: key), text: text).plaintext().count
    }

    @Test("a reply whose plaintext is exactly 159 bytes goes inline, one byte more goes over TCP")
    func asciiBoundary() throws {
        let fits = String(repeating: "a", count: SignalFrame.maxPlaintextBytes - overhead)
        #expect(try inlineBytes(fits) == 159)
        #expect(try plan(fits) == .inline(.reply(keyHash: Signal.keyHash(of: key), text: fits)))
        let over = fits + "a"
        #expect(try plan(over) == .overTcp(
            .replyOverTcp(keyHash: Signal.keyHash(of: key)), .replyText(key: key, text: over)
        ))
    }

    @Test("the boundary counts UTF-8 bytes, not characters", arguments: ["č", "€", "🙂"])
    func multiByte(_ character: String) throws {
        let width = character.utf8.count
        let count = (SignalFrame.maxPlaintextBytes - overhead) / width
        let fits = String(repeating: character, count: count)
        #expect(try inlineBytes(fits) <= 159)
        guard case .inline = try plan(fits) else {
            Issue.record("\(count) × \(character) should fit inline")
            return
        }
        let over = fits + String(repeating: character, count: 1)
        #expect(try inlineBytes(over) > 159)
        guard case .overTcp(let signal, .replyText(let fullKey, let text)) = try plan(over) else {
            Issue.record("\(count + 1) × \(character) should go over TCP")
            return
        }
        #expect(signal == .replyOverTcp(keyHash: Signal.keyHash(of: key)))
        #expect(fullKey == key && text == over)
    }

    @Test("JSON escapes count: a quote takes two bytes inline")
    func escapes() throws {
        let fits = String(repeating: "\"", count: (SignalFrame.maxPlaintextBytes - overhead) / 2)
        #expect(try inlineBytes(fits) == 159)
        guard case .inline = try plan(fits) else {
            Issue.record("escaped quotes should fit inline")
            return
        }
        guard case .overTcp = try plan(fits + "a") else {
            Issue.record("one byte over should go over TCP")
            return
        }
    }

    @Test("a reply is trimmed, and one of nothing but whitespace is not sent")
    func trimmed() {
        #expect(ReplyEncoding.trimmed("  ahoj z Macu \n") == "ahoj z Macu")
        #expect(ReplyEncoding.trimmed("a  b") == "a  b")
        #expect(ReplyEncoding.trimmed("   ") == nil)
        #expect(ReplyEncoding.trimmed("\n\t") == nil)
        #expect(ReplyEncoding.trimmed("") == nil)
    }

    @Test("a TCP reply's frame is the tcp flag alone and seals within one frame")
    func tcpFrame() throws {
        let plaintext = try Signal.replyOverTcp(keyHash: Signal.keyHash(of: key)).plaintext()
        #expect(String(decoding: plaintext, as: UTF8.self) == #"{"k":"\#(Signal.keyHash(of: key))","tcp":true}"#)
        #expect(plaintext.count <= SignalFrame.maxPlaintextBytes)
    }
}

@Suite("Pending replies")
struct PendingRepliesTests {
    private let chat = PendingReplies.Record(appLabel: "Example Chat", title: "Alice")

    @Test("a reply-error is matched to its reply once, by key hash")
    func correlation() {
        var replies = PendingReplies()
        replies.record("54892d1f759b11f6", chat)
        replies.record("778e7ebdc00b1b16", PendingReplies.Record(appLabel: "Mail", title: ""))
        let matched = replies.take("54892d1f759b11f6")
        let again = replies.take("54892d1f759b11f6")
        let unknown = replies.take("0000000000000000")
        #expect(matched == chat)
        #expect(again == nil && unknown == nil)
        #expect(replies.count == 1)
    }

    @Test("a second reply to the same notification keeps one record, the newest")
    func replaced() {
        var replies = PendingReplies()
        replies.record("54892d1f759b11f6", PendingReplies.Record(appLabel: "Example Chat", title: "Old"))
        replies.record("54892d1f759b11f6", chat)
        #expect(replies.count == 1)
        let taken = replies.take("54892d1f759b11f6")
        #expect(taken == chat)
    }

    @Test("past the cap the oldest record goes")
    func cap() {
        var replies = PendingReplies()
        for index in 0...PendingReplies.capacity {
            replies.record(String(format: "%016x", index), chat)
        }
        #expect(replies.count == PendingReplies.capacity)
        let oldest = replies.take(String(format: "%016x", 0))
        let newest = replies.take(String(format: "%016x", PendingReplies.capacity))
        #expect(oldest == nil && newest == chat)
    }

    @Test("a reply waits 30 s for its answer: reply-ok or reply-error takes it, silence makes it overdue")
    func deadline() {
        let sent = ContinuousClock.now
        var replies = PendingReplies()
        replies.record("54892d1f759b11f6", chat, at: sent)
        replies.record("778e7ebdc00b1b16", PendingReplies.Record(appLabel: "Mail", title: ""), at: sent + .seconds(5))
        #expect(PendingReplies.answerDeadline == .seconds(30))
        #expect(replies.nextDeadline == sent + .seconds(30))
        let early = replies.overdue(at: sent + .seconds(29))
        #expect(early.isEmpty)
        let answered = replies.take("778e7ebdc00b1b16")
        #expect(answered != nil, "its reply-ok came")
        let late = replies.overdue(at: sent + .seconds(30))
        #expect(late.map(\.keyHash) == ["54892d1f759b11f6"] && late.first?.record == chat)
        #expect(replies.count == 0 && replies.nextDeadline == nil)
        let afterwards = replies.take("54892d1f759b11f6")
        #expect(afterwards == nil, "an answer after the deadline matches nothing")
    }

    @Test("an unanswered reply is reported as not confirmed, not as failed")
    func unconfirmedNotice() {
        let notice = LocalNotices.replyFailed(chat, .unconfirmed)
        #expect(notice.title == "Reply not confirmed")
        #expect(notice.subtitle == "Example Chat — Alice")
        #expect(notice.body.contains("may not have been sent"))
    }

    @Test("the failure notice names the notification when known and explains the reason")
    func notice() {
        let gone = LocalNotices.replyFailed(chat, .phone(reason: "gone"))
        #expect(gone.title == "Reply failed")
        #expect(gone.subtitle == "Example Chat — Alice")
        #expect(gone.body == "The notification is no longer on your phone.")
        let unknownReason = LocalNotices.replyFailed(nil, .phone(reason: "rate-limited"))
        #expect(unknownReason.subtitle.isEmpty)
        #expect(unknownReason.body == LocalNotices.replyFailed(nil, .phone(reason: nil)).body)
        let offline = LocalNotices.replyFailed(PendingReplies.Record(appLabel: "Mail", title: ""), .notConnected)
        #expect(offline.subtitle == "Mail")
        #expect(offline.body.contains("not connected"))
    }

    @Test("a reply that never left the Mac does not blame the phone or the connection")
    func notSentNotice() {
        let unread = LocalNotices.replyFailed(nil, .notSent)
        #expect(unread.title == "Reply failed")
        #expect(unread.body == "This Mac could not send the reply.")
        #expect(!unread.body.contains("phone"))
    }
}
