import Testing

// #expect cannot take a mutating call, so each step records what it returned.
private struct Script {
    var machine: ReconcilerMachine
    var effects: [[ReconcilerMachine.Effect]] = []

    init(_ machine: ReconcilerMachine = ReconcilerMachine(), connected: Bool = true) {
        self.machine = machine
        if connected { _ = self.machine.handle(.sessionConnected) }
    }

    mutating func on(_ event: ReconcilerMachine.Event) {
        effects.append(machine.handle(event))
    }

    var last: [ReconcilerMachine.Effect] { effects.last ?? [] }
}

@Suite("Dismissal reconciler")
struct ReconcilerTests {
    @Test("armed only while something is mirrored, and disarmed when nothing is")
    func mirroredGate() {
        var script = Script()
        #expect(script.machine.armedSeconds == nil)
        #expect(script.machine.idle == .nothingMirrored)
        script.on(.mirrored(2))
        #expect(script.last == [.arm(seconds: 5)])
        script.on(.mirrored(3))
        #expect(script.last.isEmpty, "already armed")
        script.on(.mirrored(0))
        #expect(script.last == [.disarm(.nothingMirrored)])
        #expect(script.machine.armedSeconds == nil)
        script.on(.mirrored(0))
        #expect(script.last.isEmpty, "nothing scheduled, nothing to tear down")
    }

    @Test("arming needs a signal path; the session's end disarms with no signal path")
    func sessionGate() {
        var script = Script(connected: false)
        #expect(!script.machine.sessionUp)
        script.on(.mirrored(2))
        #expect(script.last.isEmpty, "mirrors left from before, but no phone to tell")
        #expect(script.machine.idle == .noSignalPath)
        #expect(ReconcilerMachine.Idle.noSignalPath.rawValue == "no session or confirmed Bluetooth link")
        script.on(.sessionConnected)
        #expect(script.last == [.pass(.connect), .arm(seconds: 5)])
        script.on(.sessionEnded)
        #expect(script.last == [.disarm(.noSignalPath)])
        #expect(script.machine.armedSeconds == nil)
        script.on(.sessionEnded)
        #expect(script.last.isEmpty)
    }

    @Test("a confirmed GATT subscription is a signal path: it passes once on the mirror as it stands and arms")
    func bluetoothGate() {
        var script = Script(connected: false)
        script.on(.mirrored(2))
        script.on(.bluetooth(linked: true))
        #expect(script.last == [.pass(.subscribe), .arm(seconds: 5)])
        #expect(ReconcilePass.subscribe.rawValue == "subscribe")
        script.on(.bluetooth(linked: true))
        #expect(script.last.isEmpty, "no second pass while it stays confirmed")
        script.on(.sessionConnected)
        #expect(script.last == [.pass(.connect)], "the connect pass still follows the first active-set")
        script.on(.sessionEnded)
        #expect(script.last.isEmpty, "a visit ending keeps the Bluetooth link armed")
        script.on(.bluetooth(linked: false))
        #expect(script.last == [.disarm(.noSignalPath)])
        script.on(.screenSlept)
        script.on(.screenWoke)
        #expect(script.last.isEmpty, "no pass without a signal path")
    }

    @Test("a confirmation with nothing mirrored passes nothing; the subscribe pass also runs event-only")
    func bluetoothQuiet() {
        var script = Script(connected: false)
        script.on(.bluetooth(linked: true))
        #expect(script.last.isEmpty)
        var eventOnly = Script(ReconcilerMachine(periodic: false), connected: false)
        eventOnly.on(.mirrored(1))
        eventOnly.on(.bluetooth(linked: true))
        #expect(eventOnly.last == [.pass(.subscribe)])
    }

    @Test("without a session the wake, unlock and connect passes are skipped too")
    func noSessionNoPasses() {
        var script = Script(connected: false)
        script.on(.mirrored(2))
        script.on(.screenSlept)
        script.on(.screenWoke)
        script.on(.screenLocked)
        script.on(.screenUnlocked)
        #expect(script.effects.joined().isEmpty)
        var eventOnly = Script(ReconcilerMachine(periodic: false))
        eventOnly.on(.mirrored(1))
        eventOnly.on(.sessionEnded)
        eventOnly.on(.screenSlept)
        eventOnly.on(.screenWoke)
        #expect(eventOnly.effects.joined().isEmpty)
        eventOnly.on(.sessionConnected)
        #expect(eventOnly.last == [.pass(.connect)])
    }

    @Test("the screen sleeping or locking disarms; waking and unlocking pass once and re-arm")
    func screenGate() {
        var script = Script()
        script.on(.mirrored(1))
        script.on(.screenSlept)
        #expect(script.last == [.disarm(.screenAsleep)])
        script.on(.screenLocked)
        #expect(script.last.isEmpty)
        script.on(.screenWoke)
        #expect(script.last == [.pass(.wake)], "awake but still locked")
        #expect(script.machine.idle == .screenLocked)
        script.on(.screenUnlocked)
        #expect(script.last == [.pass(.unlock), .arm(seconds: 5)])
        script.on(.screenLocked)
        #expect(script.last == [.disarm(.screenLocked)])
    }

    @Test("a session connecting passes once when something is mirrored")
    func connect() {
        var script = Script(connected: false)
        script.on(.sessionConnected)
        #expect(script.last.isEmpty, "nothing mirrored, nothing to check")
        script.on(.mirrored(1))
        script.on(.sessionEnded)
        script.on(.sessionConnected)
        #expect(script.last == [.pass(.connect), .arm(seconds: 5)])
    }

    @Test("event-only mode never arms but keeps the wake, unlock and connect passes")
    func eventOnly() {
        var script = Script(ReconcilerMachine(periodic: false))
        script.on(.mirrored(4))
        #expect(script.last.isEmpty)
        #expect(script.machine.idle == .eventOnly)
        script.on(.screenSlept)
        script.on(.screenWoke)
        #expect(script.last == [.pass(.wake)])
        script.on(.screenLocked)
        script.on(.screenUnlocked)
        #expect(script.last == [.pass(.unlock)])
        script.on(.sessionConnected)
        #expect(script.last == [.pass(.connect)])
        #expect(script.effects.joined().allSatisfy { if case .pass = $0 { true } else { false } })
        #expect(script.machine.armedSeconds == nil)
    }

    @Test("turning validation off disarms at once, and on again re-arms")
    func toggle() {
        var script = Script()
        script.on(.mirrored(1))
        script.on(.periodic(false))
        #expect(script.last == [.disarm(.eventOnly)])
        script.on(.periodic(true))
        #expect(script.last == [.arm(seconds: 5)])
    }

    @Test("a new interval re-arms with it; an unknown interval falls back to the default")
    func interval() {
        var script = Script()
        script.on(.mirrored(1))
        script.on(.interval(seconds: 30))
        #expect(script.last == [.arm(seconds: 30)])
        script.on(.interval(seconds: 30))
        #expect(script.last.isEmpty)
        script.on(.interval(seconds: 7))
        #expect(script.last == [.arm(seconds: ReconcilerMachine.defaultInterval)])
        #expect(ReconcilerMachine(intervalSeconds: 31).intervalSeconds == 5)
        #expect(ReconcilerMachine.defaultInterval == 5)
        #expect(ReconcilerMachine.intervals.max() == 30)
    }

    @Test("a launch with the screen asleep or locked starts disarmed")
    func launchState() {
        var asleep = Script(ReconcilerMachine(screenAwake: false))
        asleep.on(.mirrored(1))
        #expect(asleep.last.isEmpty)
        var locked = Script(ReconcilerMachine(unlocked: false))
        locked.on(.mirrored(1))
        #expect(locked.last.isEmpty)
        #expect(locked.machine.idle == .screenLocked)
    }
}
