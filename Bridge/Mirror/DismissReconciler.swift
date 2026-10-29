import Foundation
import Observation
import os

// Carries out ReconcilerMachine: the display and lock events are ScreenObserver's callbacks, and the
// only scheduled work is the periodic pass while the machine is armed, its waits stretched by
// IdlePacer while the user gives no input. Disarming cancels it, so nothing is left scheduled.
@Observable
final class DismissReconciler {
    private static let periodicKey = "reconcilerPeriodic"
    private static let intervalKey = "reconcilerInterval"

    private(set) var machine: ReconcilerMachine

    @ObservationIgnored private let pass: @Sendable (ReconcilePass) -> Void
    @ObservationIgnored private let idle: () -> Duration?
    @ObservationIgnored private let log = Logger(subsystem: "app.cue.bridge", category: "reconciler")
    @ObservationIgnored private var timer: Task<Void, Never>?

    var periodic: Bool {
        get { machine.periodic }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.periodicKey)
            handle(.periodic(newValue))
        }
    }

    var intervalSeconds: Int {
        get { machine.intervalSeconds }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.intervalKey)
            handle(.interval(seconds: newValue))
        }
    }

    init(
        screen: ScreenObserver, pass: @escaping @Sendable (ReconcilePass) -> Void,
        idle: @escaping () -> Duration? = InputIdle.duration
    ) {
        self.pass = pass
        self.idle = idle
        let defaults = UserDefaults.standard
        machine = ReconcilerMachine(
            periodic: defaults.object(forKey: Self.periodicKey) as? Bool ?? true,
            intervalSeconds: defaults.object(forKey: Self.intervalKey) as? Int ?? ReconcilerMachine.defaultInterval,
            screenAwake: screen.awake,
            unlocked: screen.unlocked
        )
        log.info(
            "reconciler ready: \(self.machine.periodic ? "periodic" : "event-only", privacy: .public), interval \(self.machine.intervalSeconds) s, screen \(self.machine.screenAwake ? "awake" : "asleep", privacy: .public), \(self.machine.unlocked ? "unlocked" : "locked", privacy: .public); no timer scheduled"
        )
        screen.listen { [weak self] event in
            switch event {
            case .slept: self?.handle(.screenSlept)
            case .woke: self?.handle(.screenWoke)
            case .systemWillSleep: break
            case .locked: self?.handle(.screenLocked)
            case .unlocked: self?.handle(.screenUnlocked)
            }
        }
    }

    func mirroredChanged(_ count: Int) {
        guard count != machine.mirrored else { return }
        handle(.mirrored(count))
    }

    func sessionConnected() {
        handle(.sessionConnected)
    }

    func sessionEnded() {
        handle(.sessionEnded)
    }

    func bluetoothChanged(linked: Bool) {
        handle(.bluetooth(linked: linked))
    }

    private func handle(_ event: ReconcilerMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case .arm(let seconds):
                arm(seconds)
            case .disarm(let idle):
                timer?.cancel()
                timer = nil
                log.info("reconciler disarmed: \(idle.rawValue, privacy: .public); no timer scheduled")
            case .pass(let reason):
                log.debug("reconcile pass requested: \(reason.rawValue, privacy: .public)")
                pass(reason)
            }
        }
        if case .periodic = event { logSettings() }
        if case .interval = event { logSettings() }
    }

    // Generous tolerance lets the wakeups coalesce with other system activity.
    private func arm(_ seconds: Int) {
        timer?.cancel()
        let interval = Duration.seconds(seconds)
        let pass = pass
        let idle = idle
        let log = log
        timer = Task {
            var pacer = IdlePacer(interval: interval, start: .now)
            while !Task.isCancelled {
                try? await Task.sleep(for: pacer.wait, tolerance: pacer.wait / 2, clock: .continuous)
                guard !Task.isCancelled else { return }
                guard pacer.fire(at: .now, idle: idle()) else {
                    let next = pacer.wait / .seconds(1)
                    log.debug("reconcile pass skipped: no input since the last pass, next in \(next, format: .fixed(precision: 0)) s")
                    continue
                }
                pass(.timer)
            }
        }
        log.info(
            "reconciler armed: every \(seconds) s, tolerance \(Double(seconds) / 2, format: .fixed(precision: 1)) s, up to \(IdlePacer.stretch)× while no input, mirrored \(self.machine.mirrored)"
        )
    }

    private func logSettings() {
        log.info(
            "reconciler settings: \(self.machine.periodic ? "periodic" : "event-only", privacy: .public), interval \(self.machine.intervalSeconds) s"
        )
    }
}
