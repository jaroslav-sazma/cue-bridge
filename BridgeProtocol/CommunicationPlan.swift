import Foundation

// A mirror shown as a communication notification: the Android app's icon is the sender's avatar and
// takes the place of the Cue: icon. The sender is the app (its package is the handle, its icon the
// image), and its name is the whole title the plain mirror shows, so the banner reads the same
// whether macOS heads it with the sender or with the content's title.
nonisolated struct CommunicationPlan: Equatable, Sendable {
    var senderName: String
    var senderHandle: String
    var conversation: String
    var avatar: Data

    // Nil keeps the plain mirror. Without the entitlement — every ad-hoc build — macOS would not
    // apply the style, and without the icon's bytes there is no avatar to replace the app icon with;
    // `avatar` is asked only when both of the rest hold, so an ad-hoc build reads no file for it.
    static func make(
        _ info: NotificationInfo, entitled: Bool, avatar: (String) -> Data?
    ) -> CommunicationPlan? {
        guard entitled, let hash = info.iconHash, let png = avatar(hash), !png.isEmpty else { return nil }
        return CommunicationPlan(
            senderName: MirrorRendering.title(info), senderHandle: info.pkg,
            conversation: MirrorRendering.threadIdentifier(info), avatar: png
        )
    }
}

nonisolated enum MirrorIconPlacement: Equatable, Sendable {
    case avatar
    case attachment

    // The thumbnail beside an avatar would show the same icon twice; whatever kept the style from
    // applying leaves today's look, the app icon with the thumbnail.
    static func choose(styled: Bool) -> MirrorIconPlacement {
        styled ? .avatar : .attachment
    }
}
