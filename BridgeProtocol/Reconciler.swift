import Foundation

nonisolated enum ReconcilePass: String, Sendable {
    case timer
    case wake
    case unlock
    case connect
    case subscribe
}

// The bounded dismissal reconciler: a periodic pass only while something is mirrored, a signal path
// to the phone is up and the display is awake and unlocked, torn down to no timer otherwise;
// one-shot passes on wake, unlock, connect and subscribe in either mode. The signal path is a
// session that sent its first active-set or a GATT subscription confirmed as the phone's; the
// subscribe pass runs on that confirmation, never on a bare subscription. Without either a
// dismissal found could not reach the phone and would only be dropped, so no pass runs then; the
// connect pass, or the subscribe pass on the mirror as it stands, catches up.
nonisolated struct ReconcilerMachine: Equatable, Sendable {
    static let intervals = [3, 5, 10, 30]
    static let defaultInterval = 5

    enum Event: Equatable, Sendable {
        case mirrored(Int)
        case screenSlept
        case screenWoke
        case screenLocked
        case screenUnlocked
        case sessionConnected
        case sessionEnded
        case bluetooth(linked: Bool)
        case periodic(Bool)
        case interval(seconds: Int)
    }

    enum Idle: String, Equatable, Sendable {
        case eventOnly = "periodic validation off"
        case nothingMirrored = "nothing mirrored"
        case noSignalPath = "no session or confirmed Bluetooth link"
        case screenAsleep = "screen asleep"
        case screenLocked = "screen locked"
    }

    enum Effect: Equatable, Sendable {
        case arm(seconds: Int)
        case disarm(Idle)
        case pass(ReconcilePass)
    }

    private(set) var periodic: Bool
    private(set) var intervalSeconds: Int
    private(set) var mirrored = 0
    private(set) var screenAwake: Bool
    private(set) var unlocked: Bool
    private(set) var sessionUp = false
    private(set) var bluetoothUp = false
    private(set) var armedSeconds: Int?

    var signalPathUp: Bool { sessionUp || bluetoothUp }

    init(periodic: Bool = true, intervalSeconds: Int = defaultInterval, screenAwake: Bool = true, unlocked: Bool = true) {
        self.periodic = periodic
        self.intervalSeconds = Self.validInterval(intervalSeconds)
        self.screenAwake = screenAwake
        self.unlocked = unlocked
    }

    static func validInterval(_ seconds: Int) -> Int {
        intervals.contains(seconds) ? seconds : defaultInterval
    }

    var idle: Idle? {
        if !periodic { return .eventOnly }
        if mirrored == 0 { return .nothingMirrored }
        if !signalPathUp { return .noSignalPath }
        if !screenAwake { return .screenAsleep }
        if !unlocked { return .screenLocked }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        var effects: [Effect] = []
        switch event {
        case .mirrored(let count):
            mirrored = max(0, count)
        case .screenSlept:
            screenAwake = false
        case .screenWoke:
            screenAwake = true
            effects += pass(.wake)
        case .screenLocked:
            unlocked = false
        case .screenUnlocked:
            unlocked = true
            effects += pass(.unlock)
        case .sessionConnected:
            sessionUp = true
            effects += pass(.connect)
        case .sessionEnded:
            sessionUp = false
        case .bluetooth(let linked):
            let rose = linked && !bluetoothUp
            bluetoothUp = linked
            if rose { effects += pass(.subscribe) }
        case .periodic(let on):
            periodic = on
        case .interval(let seconds):
            intervalSeconds = Self.validInterval(seconds)
        }
        return effects + settle()
    }

    private func pass(_ reason: ReconcilePass) -> [Effect] {
        mirrored > 0 && signalPathUp ? [.pass(reason)] : []
    }

    private mutating func settle() -> [Effect] {
        if let idle {
            guard armedSeconds != nil else { return [] }
            armedSeconds = nil
            return [.disarm(idle)]
        }
        guard armedSeconds != intervalSeconds else { return [] }
        armedSeconds = intervalSeconds
        return [.arm(seconds: intervalSeconds)]
    }
}
