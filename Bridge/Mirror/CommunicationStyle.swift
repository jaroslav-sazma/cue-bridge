import Foundation
import Intents
import Security
import UserNotifications
import os

// Dormant under the ad-hoc signature: it acts only when the running binary carries the restricted
// entitlement, which needs a real signing identity and a provisioning profile. Without it nothing
// here calls into Intents.
nonisolated struct CommunicationStyle: Sendable {
    static let entitlement = "com.apple.developer.usernotifications.communication"

    let entitled: Bool
    private let log = Logger(subsystem: "app.cue.bridge", category: "mirror")

    init() {
        let entitled = Self.carriesEntitlement()
        self.entitled = entitled
        log.debug("communication notifications \(entitled ? "entitled" : "not entitled, mirrors stay plain", privacy: .public)")
    }

    func plan(_ info: NotificationInfo, icons: IconCache) -> CommunicationPlan? {
        CommunicationPlan.make(info, entitled: entitled, avatar: icons.png)
    }

    // Nil on any failure, and the caller posts the plain content with its attachment. The message
    // text stays out of the intent: the donation needs only who sent it.
    func styled(_ content: UNMutableNotificationContent, _ plan: CommunicationPlan, keyHash: String) async -> UNNotificationContent? {
        let avatar = INImage(imageData: plan.avatar)
        let sender = INPerson(
            personHandle: INPersonHandle(value: plan.senderHandle, type: .unknown), nameComponents: nil,
            displayName: plan.senderName, image: avatar, contactIdentifier: nil, customIdentifier: plan.senderHandle,
            isMe: false
        )
        let intent = INSendMessageIntent(
            recipients: nil, outgoingMessageType: .outgoingMessageText, content: nil, speakableGroupName: nil,
            conversationIdentifier: plan.conversation, serviceName: nil, sender: sender, attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return try content.updating(from: intent)
        } catch {
            log.info("mirror k=\(keyHash, privacy: .public) posted plain, communication style refused: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func forgetDonations() async {
        guard entitled else { return }
        do {
            try await INInteraction.deleteAll()
        } catch {
            log.error("donated interactions not deleted: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func carriesEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, entitlement as CFString, nil) as? Bool == true
    }
}
