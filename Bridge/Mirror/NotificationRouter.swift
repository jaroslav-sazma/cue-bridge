import Foundation
import UserNotifications

// The app's one UNUserNotificationCenterDelegate. Set at launch, not on first use: a response to a
// notification left over from an earlier run only reaches the delegate if it is already in place.
// setNotificationCategories replaces the whole set, so every category is registered here.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private let mirror: NotificationMirror
    private let clicks: ClickStore

    init(mirror: NotificationMirror, clicks: ClickStore) {
        self.mirror = mirror
        self.clicks = clicks
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationMirror.categoryDefinitions())
    }

    // Called only while the app is active, e.g. with the pairing window in front.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        notification.request.content.interruptionLevel == .passive ? [.list] : [.banner, .list, .sound]
    }

    // Dismissals arrive here together with taps and replies; only actionIdentifier tells them apart.
    // Of the Mac's own notices (flash, reply failed, clipboard) only the flash's "Set Click Action…"
    // is answered; other responses to them and to foreign categories are dropped.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let request = response.notification.request
        if request.content.categoryIdentifier == NotificationMirror.flashCategory,
           response.actionIdentifier == NotificationMirror.setClickAction {
            await openClickSettings(PhoneApp(userInfo: request.content.userInfo))
            return
        }
        guard NotificationMirror.isMirror(request.content.categoryIdentifier), Signal.isKeyHash(request.identifier)
        else { return }
        let kind: NotificationMirror.Response = switch response.actionIdentifier {
        case UNNotificationDismissActionIdentifier:
            .dismissed
        case UNNotificationDefaultActionIdentifier:
            .opened
        case NotificationMirror.replyAction:
            (response as? UNTextInputNotificationResponse).map { .replied(text: $0.userText) } ?? .other(response.actionIdentifier)
        default:
            .other(response.actionIdentifier)
        }
        mirror.submit(.response(
            keyHash: request.identifier, entry: MirrorEntry(userInfo: request.content.userInfo), kind
        ))
    }

    private func openClickSettings(_ app: PhoneApp?) {
        clicks.requestSettings(for: app)
    }
}
