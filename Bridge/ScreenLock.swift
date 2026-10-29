import CoreGraphics
import Darwin

// SACLockScreenImmediate is private API of login.framework, resolved at run time and never linked:
// a macOS without it only loses locking, and the hardened runtime loads it as an Apple-signed image.
nonisolated enum ScreenLock {
    private typealias LockFunction = @convention(c) () -> Int32

    private static let lockFunction: LockFunction? = {
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
            let symbol = dlsym(handle, "SACLockScreenImmediate")
        else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    static var available: Bool { lockFunction != nil }

    // Nil when the session dictionary cannot be read; a missing key means unlocked.
    static func isLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    // The function's result, or nil when it is not available.
    static func lock() -> Int32? {
        lockFunction?()
    }
}
