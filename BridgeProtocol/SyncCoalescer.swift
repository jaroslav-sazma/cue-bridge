import Foundation

nonisolated enum SyncAsk: Equatable, Sendable {
    case send
    case folded
    case summon
}

// At most one sync-request is outstanding on a session. Doorbells and display wakes that ask while one
// is outstanding fold into exactly one more, sent when the awaited active-set arrives. A new session
// starts with one outstanding: the phone sends its active-set unprompted after hello. Without a
// session nothing is coalesced: every ask sends its own sync-request frame over GATT, because the
// phone makes one connection attempt per summon and a summon during its visit is a no-op there.
nonisolated struct SyncCoalescer: Equatable, Sendable {
    private(set) var outstanding = false
    private(set) var again = false

    mutating func sessionStarted() {
        outstanding = true
        again = false
    }

    mutating func sessionEnded() {
        outstanding = false
        again = false
    }

    mutating func ask(sessionUp: Bool) -> SyncAsk {
        guard sessionUp else { return .summon }
        return requested() ? .send : .folded
    }

    // True when a sync-request has to be sent now.
    mutating func requested() -> Bool {
        if outstanding {
            again = true
            return false
        }
        outstanding = true
        return true
    }

    mutating func activeSetReceived() -> Bool {
        guard again else {
            outstanding = false
            return false
        }
        again = false
        outstanding = true
        return true
    }
}
