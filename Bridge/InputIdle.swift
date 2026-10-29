import CoreGraphics

// The time since the user last touched a key, the pointer or the trackpad in this login session.
nonisolated enum InputIdle {
    // kCGAnyInputEventType, which Swift does not import by name.
    private static let anyInput = CGEventType(rawValue: ~0)!

    static func duration() -> Duration? {
        let seconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return .milliseconds(Int64(seconds * 1000))
    }
}
