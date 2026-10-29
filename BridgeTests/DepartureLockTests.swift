import Testing

private let t0 = SuspendingClock.now

private func at(minutes: Double) -> SuspendingClock.Instant {
    t0 + .seconds(minutes * 60)
}

// A linked snapshot is a fresh confirmation unless `stale` says it is one left over from before.
private func link(
    _ phoneLinked: Bool, radioOn: Bool = true, paired: Bool = true, stale: Bool = false
) -> DepartureLock.Link {
    DepartureLock.Link(phoneLinked: phoneLinked, radioOn: radioOn, paired: paired, confirmedNow: phoneLinked && !stale)
}

private func linkedLock(delayMinutes: Int = 1) -> DepartureLock {
    var lock = DepartureLock(enabled: true, delayMinutes: delayMinutes)
    lock.linkChanged(link(true), at: t0)
    return lock
}

@Suite("Auto-lock on departure")
struct DepartureLockTests {
    @Test("the end of the last confirmed subscription arms the configured delay")
    func armsOnDeparture() {
        var lock = linkedLock(delayMinutes: 5)
        #expect(!lock.armed)
        lock.linkChanged(link(false), at: at(minutes: 1))
        #expect(lock.deadline == at(minutes: 6))
        let early = lock.fire(at: at(minutes: 5.9), screenLocked: false)
        #expect(early == nil)
        #expect(lock.armed)
        let due = lock.fire(at: at(minutes: 6), screenLocked: false)
        #expect(due == .lock)
        #expect(!lock.armed)
    }

    @Test("a subscriber confirmed again cancels the timer")
    func reconfirmCancels() {
        var lock = linkedLock()
        lock.linkChanged(link(false), at: at(minutes: 0))
        lock.linkChanged(link(true), at: at(minutes: 0.5))
        #expect(!lock.armed)
        let fired = lock.fire(at: at(minutes: 2), screenLocked: false)
        #expect(fired == nil)
    }

    @Test("a fired departure does not arm again until a confirmed subscription has been back")
    func oneShot() {
        var lock = linkedLock()
        lock.linkChanged(link(false), at: at(minutes: 0))
        let first = lock.fire(at: at(minutes: 1), screenLocked: false)
        #expect(first == .lock)
        lock.linkChanged(link(false), at: at(minutes: 3))
        lock.linkChanged(link(false), at: at(minutes: 10))
        #expect(!lock.armed)
        lock.linkChanged(link(true), at: at(minutes: 20))
        lock.linkChanged(link(false), at: at(minutes: 21))
        #expect(lock.deadline == at(minutes: 22))
    }

    @Test("a phone that was never confirmed is no departure")
    func neverLinked() {
        var lock = DepartureLock(enabled: true)
        lock.linkChanged(link(false), at: t0)
        #expect(!lock.armed)
    }

    @Test("this Mac's Bluetooth going off neither arms nor counts as a departure later")
    func radioOff() {
        var lock = linkedLock()
        lock.linkChanged(link(false, radioOn: false), at: at(minutes: 0))
        #expect(!lock.armed)
        lock.linkChanged(link(false, radioOn: true), at: at(minutes: 1))
        #expect(!lock.armed)
    }

    @Test("the radio going off cancels an armed timer")
    func radioOffCancels() {
        var lock = linkedLock()
        lock.linkChanged(link(false), at: at(minutes: 0))
        lock.linkChanged(link(false, radioOn: false), at: at(minutes: 0.5))
        #expect(!lock.armed)
        let fired = lock.fire(at: at(minutes: 1), screenLocked: false)
        #expect(fired == nil)
    }

    @Test("unpairing or a new pairing cancels and forgets the link")
    func pairingChanged() {
        var lock = linkedLock()
        lock.linkChanged(link(false, paired: false), at: at(minutes: 0))
        #expect(!lock.armed)

        var repaired = linkedLock()
        repaired.linkChanged(link(false), at: at(minutes: 0))
        repaired.forget()
        #expect(!repaired.armed)
        repaired.linkChanged(link(false), at: at(minutes: 1))
        #expect(!repaired.armed)
    }

    @Test("a screen already locked at the deadline is left alone, and that still uses the departure up")
    func alreadyLocked() {
        var lock = linkedLock()
        lock.linkChanged(link(false), at: at(minutes: 0))
        let fired = lock.fire(at: at(minutes: 1), screenLocked: true)
        #expect(fired == .alreadyLocked)
        lock.linkChanged(link(false), at: at(minutes: 2))
        #expect(!lock.armed)
    }

    @Test("off by default; turning it off disarms, turning it on arms only at the next departure")
    func setting() {
        var lock = DepartureLock()
        #expect(!lock.enabled && lock.delayMinutes == 1)
        lock.linkChanged(link(true), at: t0)
        lock.linkChanged(link(false), at: at(minutes: 0))
        #expect(!lock.armed)
        lock.configure(enabled: true, delayMinutes: 2)
        #expect(!lock.armed)
        lock.linkChanged(link(true), at: at(minutes: 1))
        lock.linkChanged(link(false), at: at(minutes: 2))
        #expect(lock.deadline == at(minutes: 4))
        lock.configure(enabled: false, delayMinutes: 2)
        #expect(!lock.armed)
    }

    @Test("this Mac going to sleep disarms a pending departure, which does not fire at wake")
    func sleepDisarms() {
        var lock = linkedLock()
        lock.linkChanged(link(false), at: at(minutes: 0))
        #expect(lock.armed)
        lock.forget()
        #expect(!lock.armed)
        let atWake = lock.fire(at: at(minutes: 90), screenLocked: false)
        #expect(atWake == nil)
        lock.linkChanged(link(false), at: at(minutes: 90))
        #expect(!lock.armed)
    }

    @Test("a subscription still confirmed from before the sleep and reported gone at wake does not arm")
    func dropReportedAtWake() {
        var lock = linkedLock()
        lock.forget()
        lock.linkChanged(link(true, stale: true), at: at(minutes: 60))
        #expect(!lock.armed)
        lock.linkChanged(link(false), at: at(minutes: 60))
        #expect(!lock.armed)
    }

    @Test("the Mac adding its service again ends the subscription without a departure")
    func serviceReadded() {
        var lock = linkedLock()
        lock.subscriptionsDroppedByMac()
        lock.linkChanged(link(false), at: at(minutes: 0))
        #expect(!lock.armed)
        lock.linkChanged(link(true), at: at(minutes: 1))
        lock.linkChanged(link(false), at: at(minutes: 2))
        #expect(lock.deadline == at(minutes: 3), "the phone's own departure after it confirmed again")
    }

    @Test("the Mac adding its service again keeps a departure already pending")
    func serviceReaddedAfterDeparture() {
        var lock = linkedLock()
        lock.linkChanged(link(false), at: at(minutes: 0))
        lock.subscriptionsDroppedByMac()
        lock.linkChanged(link(false), at: at(minutes: 0.5))
        #expect(lock.deadline == at(minutes: 1))
    }

    @Test("after a wake a subscription confirmed again and then ended arms as usual")
    func departureAfterWake() {
        var lock = linkedLock()
        lock.forget()
        lock.linkChanged(link(false), at: at(minutes: 60))
        lock.linkChanged(link(true), at: at(minutes: 61))
        #expect(!lock.armed)
        lock.linkChanged(link(false), at: at(minutes: 62))
        #expect(lock.deadline == at(minutes: 63))
        let due = lock.fire(at: at(minutes: 63), screenLocked: false)
        #expect(due == .lock)
    }

    @Test("a link counts only from a confirmation made after the last forget")
    func onlyFreshConfirmation() {
        var lock = DepartureLock(enabled: true)
        lock.linkChanged(link(true, stale: true), at: t0)
        lock.linkChanged(link(false), at: at(minutes: 1))
        #expect(!lock.armed)
        lock.linkChanged(link(true), at: at(minutes: 2))
        lock.linkChanged(link(true, stale: true), at: at(minutes: 3))
        lock.linkChanged(link(false), at: at(minutes: 4))
        #expect(lock.deadline == at(minutes: 5), "a confirmed link stays linked through later changes")
    }

    @Test("a delay outside the choices falls back to one minute")
    func delays() {
        #expect(DepartureLock.delays == [1, 2, 5, 15])
        #expect(DepartureLock(enabled: true, delayMinutes: 0).delayMinutes == 1)
        var lock = DepartureLock(enabled: true, delayMinutes: 15)
        lock.configure(enabled: true, delayMinutes: 7)
        #expect(lock.delayMinutes == 1)
    }
}
