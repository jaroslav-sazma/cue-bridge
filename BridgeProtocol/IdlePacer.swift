import Foundation

// The waits of a periodic pass that looks for what the user did — a dismissal in Notification
// Center, a copy. While no input has come since the last pass there is nothing new to find: the pass
// is skipped and the next wait doubles, up to `stretch` times the interval. Input since the last
// pass brings the pass back, and the interval with it. It stays one timer; only its waits lengthen.
// An unknown idle time always passes.
nonisolated struct IdlePacer: Equatable, Sendable {
    static let stretch = 4

    let interval: Duration
    private(set) var wait: Duration
    private(set) var lastPass: ContinuousClock.Instant

    init(interval: Duration, start: ContinuousClock.Instant) {
        self.interval = interval
        wait = interval
        lastPass = start
    }

    var ceiling: Duration { interval * Self.stretch }

    // `idle` is the time since the user's last input; true when the pass is to run.
    mutating func fire(at now: ContinuousClock.Instant, idle: Duration?) -> Bool {
        if let idle, idle >= now - lastPass {
            wait = min(wait * 2, ceiling)
            return false
        }
        lastPass = now
        wait = interval
        return true
    }
}
