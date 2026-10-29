import Foundation

// This Mac's own choices, unlike PhoneSwitches kept across pairings: they are the user's, not the
// phone's.
nonisolated enum MacSwitches {
    private static let clipboardKey = "clipboardToPhone"

    static var clipboardToPhone: Bool {
        UserDefaults.standard.object(forKey: clipboardKey) as? Bool ?? true
    }

    static func save(clipboardToPhone: Bool) {
        UserDefaults.standard.set(clipboardToPhone, forKey: clipboardKey)
    }

    private static let autoLockKey = "lockWhenPhoneLeaves"
    private static let autoLockDelayKey = "lockWhenPhoneLeavesMinutes"

    static var autoLock: Bool {
        UserDefaults.standard.object(forKey: autoLockKey) as? Bool ?? false
    }

    static var autoLockMinutes: Int {
        let stored = UserDefaults.standard.integer(forKey: autoLockDelayKey)
        return DepartureLock.delays.contains(stored) ? stored : DepartureLock.defaultDelay
    }

    static func save(autoLock: Bool, minutes: Int) {
        UserDefaults.standard.set(autoLock, forKey: autoLockKey)
        UserDefaults.standard.set(minutes, forKey: autoLockDelayKey)
    }
}
