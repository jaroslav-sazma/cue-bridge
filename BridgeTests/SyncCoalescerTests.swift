import Testing

// #expect cannot take a mutating call, so each step records what it returned.
private struct Script {
    var coalescer = SyncCoalescer()
    var sent: [Bool] = []

    mutating func doorbell() {
        sent.append(coalescer.requested())
    }

    mutating func activeSet() {
        sent.append(coalescer.activeSetReceived())
    }
}

@Suite("Doorbell coalescing")
struct SyncCoalescerTests {
    @Test("a doorbell before the session's first active-set waits for it, then asks once")
    func firstActiveSet() {
        var script = Script()
        script.coalescer.sessionStarted()
        script.doorbell()
        script.doorbell()
        script.activeSet()
        script.activeSet()
        #expect(script.sent == [false, false, true, false])
        #expect(!script.coalescer.outstanding)
    }

    @Test("an idle session asks at once; doorbells meanwhile fold into exactly one more")
    func folding() {
        var script = Script()
        script.coalescer.sessionStarted()
        script.activeSet()
        script.doorbell()
        for _ in 0..<5 {
            script.doorbell()
        }
        script.activeSet()
        script.activeSet()
        script.doorbell()
        #expect(script.sent == [false, true, false, false, false, false, false, true, false, true])
    }

    @Test("a wake asks like a doorbell: on a session once, folded while outstanding; without one it summons")
    func wake() {
        var coalescer = SyncCoalescer()
        let away = coalescer.ask(sessionUp: false)
        coalescer.sessionStarted()
        _ = coalescer.activeSetReceived()
        let first = coalescer.ask(sessionUp: true)
        let second = coalescer.ask(sessionUp: true)
        let third = coalescer.ask(sessionUp: true)
        let more = coalescer.activeSetReceived()
        let done = coalescer.activeSetReceived()
        #expect(away == .summon)
        #expect([first, second, third] == [.send, .folded, .folded])
        #expect(more && !done, "exactly one more sync-request, then quiet")
    }

    @Test("an ended session forgets what was outstanding")
    func sessionEnd() {
        var script = Script()
        script.coalescer.sessionStarted()
        script.doorbell()
        script.coalescer.sessionEnded()
        #expect(!script.coalescer.outstanding && !script.coalescer.again)
        script.coalescer.sessionStarted()
        script.activeSet()
        #expect(script.sent == [false, false])
    }
}
