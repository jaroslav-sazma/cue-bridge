import Foundation
import Testing

private let hash = String(repeating: "c", count: 64)
private let png = Data([0x89, 0x50, 0x4E, 0x47])

private func info(title: String = "Alice", threadId: String? = "com.example.chat/alice", iconHash: String? = hash) -> NotificationInfo {
    NotificationInfo(
        key: "0|com.example.chat|42|null|10123", pkg: "com.example.chat", appLabel: "Example Chat", title: title,
        text: "Hi", when: 1_791_820_800_000, threadId: threadId, canReply: true, isClearable: true, iconHash: iconHash
    )
}

@Suite("Communication notifications")
struct CommunicationPlanTests {
    @Test("the sender is the app: its package as the handle, its icon as the avatar, the mirror's title as the name")
    func sender() {
        let plan = CommunicationPlan.make(info(), entitled: true) { $0 == hash ? png : nil }
        #expect(plan == CommunicationPlan(
            senderName: "Example Chat — Alice", senderHandle: "com.example.chat",
            conversation: "com.example.chat/alice", avatar: png
        ))
    }

    @Test("an untitled notification names the app alone, and a missing thread falls back to the package")
    func fallbacks() {
        let plan = CommunicationPlan.make(info(title: "", threadId: nil), entitled: true) { _ in png }
        #expect(plan?.senderName == "Example Chat")
        #expect(plan?.conversation == "com.example.chat")
    }

    @Test("without the entitlement the plain mirror stays and no icon is read")
    func notEntitled() {
        var asked = false
        let plan = CommunicationPlan.make(info(), entitled: false) { _ in
            asked = true
            return png
        }
        #expect(plan == nil)
        #expect(!asked)
    }

    @Test("without an icon there is no avatar, so the plain mirror stays")
    func noIcon() {
        #expect(CommunicationPlan.make(info(iconHash: nil), entitled: true) { _ in png } == nil)
        #expect(CommunicationPlan.make(info(), entitled: true) { _ in nil } == nil)
        #expect(CommunicationPlan.make(info(), entitled: true) { _ in Data() } == nil)
    }

    @Test("the thumbnail is attached only when the style did not apply")
    func placement() {
        #expect(MirrorIconPlacement.choose(styled: true) == .avatar)
        #expect(MirrorIconPlacement.choose(styled: false) == .attachment)
    }
}
