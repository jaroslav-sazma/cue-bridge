import AppKit
import CoreGraphics
import os

enum ScreenEvent {
    case slept
    case woke
    case systemWillSleep
    case locked
    case unlocked
}

// The display, sleep and lock observers the bounded timers gate on, shared by the dismissal
// reconciler, the clipboard publisher, the lock-state the phone is told and the departure auto-lock.
// Callbacks only; nothing is scheduled here.
final class ScreenObserver {
    private(set) var awake: Bool
    private(set) var unlocked: Bool

    private let log = Logger(subsystem: "app.cue.bridge", category: "screen")
    private var listeners: [(ScreenEvent) -> Void] = []
    private var observers: [any NSObjectProtocol] = []

    init() {
        let locked = ScreenLock.isLocked() ?? false
        awake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        unlocked = !locked
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, .slept)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .woke)
        observe(workspace, NSWorkspace.willSleepNotification, .systemWillSleep)
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .locked)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .unlocked)
    }

    func listen(_ listener: @escaping (ScreenEvent) -> Void) {
        listeners.append(listener)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: ScreenEvent) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.changed(event) }
        }
        observers.append(token)
    }

    private func changed(_ event: ScreenEvent) {
        let name: String
        switch event {
        case .slept:
            awake = false
            name = "screen asleep"
        case .woke:
            awake = true
            name = "screen awake"
        case .systemWillSleep:
            name = "Mac going to sleep"
        case .locked:
            unlocked = false
            name = "screen locked"
        case .unlocked:
            unlocked = true
            name = "screen unlocked"
        }
        log.info("\(name, privacy: .public)")
        for listener in listeners {
            listener(event)
        }
    }
}
