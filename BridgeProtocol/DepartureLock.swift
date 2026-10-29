import Foundation

nonisolated enum DepartureOutcome: Equatable, Sendable {
    case lock
    case alreadyLocked
}

// Only the end of the last confirmed subscription is a departure: a radio that went off, a pairing
// that changed or this Mac going to sleep is this Mac's doing, not the phone's, and forgets the link
// instead, as does the Mac adding its service again, which ends every subscription itself. A link
// counts only from a confirmation made after the last forget, so a subscription still confirmed from
// before a sleep cannot be taken up at wake and then count when its stale end is reported. A
// departure locks at most once — re-arming needs the link back first — so a phone that stays away
// does not lock the Mac again after every unlock. A changed delay applies to the next departure.
// The deadline is on the suspending clock: sleep does not count towards the delay, so a forget that
// reaches the actor only at wake still comes before the timer.
nonisolated struct DepartureLock: Equatable, Sendable {
    // Minutes. No zero: a link at the edge of range comes and goes.
    static let delays = [1, 2, 5, 15]
    static let defaultDelay = 1

    struct Link: Equatable, Sendable {
        var phoneLinked: Bool
        var radioOn: Bool
        var paired: Bool
        // This very change confirmed a subscription as the phone's.
        var confirmedNow = false
    }

    private(set) var enabled: Bool
    private(set) var delayMinutes: Int
    private(set) var deadline: SuspendingClock.Instant?
    private var linked = false

    init(enabled: Bool = false, delayMinutes: Int = defaultDelay) {
        self.enabled = enabled
        self.delayMinutes = Self.delays.contains(delayMinutes) ? delayMinutes : Self.defaultDelay
    }

    var armed: Bool { deadline != nil }

    var delay: Duration { .seconds(delayMinutes * 60) }

    mutating func configure(enabled: Bool, delayMinutes: Int) {
        self.enabled = enabled
        self.delayMinutes = Self.delays.contains(delayMinutes) ? delayMinutes : Self.defaultDelay
        if !enabled { deadline = nil }
    }

    mutating func linkChanged(_ link: Link, at now: SuspendingClock.Instant = .now) {
        let wasLinked = linked
        guard link.paired, link.radioOn else {
            forget()
            return
        }
        linked = link.phoneLinked && (linked || link.confirmedNow)
        if linked {
            deadline = nil
        } else if wasLinked, enabled {
            deadline = now + delay
        }
    }

    // A radio off, a pairing changed, this Mac going to sleep: no departure, and none pending.
    mutating func forget() {
        linked = false
        deadline = nil
    }

    // The Mac added its service again and so ended the subscriptions itself. A departure already
    // pending stays: the phone had left before.
    mutating func subscriptionsDroppedByMac() {
        linked = false
    }

    // Nil while not armed or before the deadline.
    mutating func fire(at now: SuspendingClock.Instant = .now, screenLocked: Bool) -> DepartureOutcome? {
        guard let deadline, now >= deadline else { return nil }
        self.deadline = nil
        return screenLocked ? .alreadyLocked : .lock
    }
}
