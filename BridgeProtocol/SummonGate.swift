import Foundation

nonisolated enum SummonReason: String, Equatable, Sendable {
    case doorbell
    case wake
    case confirmed = "confirmed subscriber"
}

nonisolated enum SummonDecision: Equatable, Sendable {
    case summon
    case deferred
    case recentSync
}

// When the Mac may make the phone open a session over GATT. While the display sleeps nobody looks
// at the mirror, so summons wait, and the display's wake asks for the set once for all of them;
// frames that arrive meanwhile are still applied. A Bluetooth link that comes back at the edge of
// range would summon a visit with every reconnect, so a fresh confirmation does not summon while a
// set arrived within `freshSync` and the display has not slept since: what the phone posts
// meanwhile rings its own doorbell.
nonisolated struct SummonGate: Equatable, Sendable {
    static let freshSync = Duration.seconds(180)

    private(set) var displayAwake: Bool
    private(set) var deferred = 0
    private(set) var lastSync: ContinuousClock.Instant?

    init(displayAwake: Bool = true) {
        self.displayAwake = displayAwake
    }

    mutating func ask(_ reason: SummonReason, at now: ContinuousClock.Instant) -> SummonDecision {
        guard displayAwake else {
            deferred += 1
            return .deferred
        }
        if reason == .confirmed, let lastSync, now - lastSync < Self.freshSync { return .recentSync }
        return .summon
    }

    mutating func synced(at now: ContinuousClock.Instant) {
        lastSync = now
    }

    mutating func displaySlept() {
        displayAwake = false
        lastSync = nil
    }

    // How many summons waited for this wake; the wake's own ask stands for all of them.
    mutating func displayWoke() -> Int {
        displayAwake = true
        defer { deferred = 0 }
        return deferred
    }

    mutating func pairingChanged() {
        lastSync = nil
        deferred = 0
    }
}
