import Foundation

// The paired phone's switches as its last session hello gave them, kept between sessions so that the
// Bluetooth path between them follows the phone's choice too. Unknown counts as off: nothing leaves
// the pasteboard before a hello allowed it, and a new pairing or an unpairing forgets the old answer.
nonisolated enum PhoneSwitches {
    private static let clipboardKey = "phoneClipboardFromMac"

    static var clipboardFromMac: Bool {
        UserDefaults.standard.bool(forKey: clipboardKey)
    }

    static func save(clipboardFromMac: Bool) {
        UserDefaults.standard.set(clipboardFromMac, forKey: clipboardKey)
    }

    static func forget() {
        UserDefaults.standard.removeObject(forKey: clipboardKey)
    }
}
