import Foundation
import Observation
import os
import Synchronization

@Observable
final class BridgeController {
    private(set) var status = BridgeStatus()
    private(set) var menuBar = MenuBarState.notPaired
    private(set) var clipboardToPhone = MacSwitches.clipboardToPhone
    private(set) var autoLock = MacSwitches.autoLock
    private(set) var autoLockMinutes = MacSwitches.autoLockMinutes
    @ObservationIgnored let canLockScreen = ScreenLock.available

    @ObservationIgnored let server: BridgeServer
    @ObservationIgnored let reconciler: DismissReconciler
    @ObservationIgnored let clicks: ClickStore
    @ObservationIgnored let icons: IconCache
    @ObservationIgnored private let screen: ScreenObserver
    @ObservationIgnored private let clipboard: ClipboardPublisher
    @ObservationIgnored private let router: NotificationRouter
    // One stream keeps the server's pairing calls in the order they were made: a start and a dismiss
    // in separate tasks could reach the server swapped.
    @ObservationIgnored private let pairingCommands: AsyncStream<PairingCommand>.Continuation
    @ObservationIgnored private var pairingWindowAppearances = 0
    // Ordered like the pairing calls, and only the newest choice matters.
    @ObservationIgnored private let autoLockSettings: AsyncStream<DepartureLock>.Continuation
    @ObservationIgnored private let log = Logger(subsystem: "app.cue.bridge", category: "pairing")
    #if DEBUG
    @ObservationIgnored private let bridgectl: BridgectlServer
    #endif

    init() {
        let (updates, continuation) = AsyncStream.makeStream(
            of: BridgeStatus.self, bufferingPolicy: .bufferingNewest(1)
        )
        let (reports, reportContinuation) = AsyncStream.makeStream(of: NotificationMirror.Report.self)
        let icons = IconCache()
        let clicks = ClickStore()
        // The mirror sends through the server, which is built after it and needs it.
        let slot = ServerSlot()
        // One stream keeps a quick end-and-reconnect (a replaced session) in order on the main actor.
        let (sessions, sessionContinuation) = AsyncStream.makeStream(of: SessionEvent.self)
        let (clips, clipContinuation) = AsyncStream.makeStream(of: IncomingClip.self)
        let mirror = NotificationMirror(
            icons: icons, clicks: clicks, report: { reportContinuation.yield($0) },
            outbound: { await slot.server?.deliver($0) ?? .noSession }
        )
        let screen = ScreenObserver()
        let reconciler = DismissReconciler(screen: screen, pass: { mirror.submit(.reconcile($0)) })
        // One stream: a lock and an unlock in quick succession must reach the phone in that order.
        let (locks, lockContinuation) = AsyncStream.makeStream(of: Bool.self)
        screen.listen { event in
            switch event {
            case .slept: Task { await slot.server?.screenSlept() }
            case .woke: Task { await slot.server?.screenWoke() }
            case .systemWillSleep: Task { await slot.server?.systemWillSleep() }
            case .locked: lockContinuation.yield(true)
            case .unlocked: lockContinuation.yield(false)
            }
        }
        let clipboard = ClipboardPublisher(
            screen: screen, phoneTakesClips: PhoneSwitches.clipboardFromMac, macSendsClips: MacSwitches.clipboardToPhone,
            deliver: { await slot.server?.deliverClipboard($0) ?? .noSession },
            signalPending: { await slot.server?.sendClipboardPending() ?? false },
            announce: { mirror.submit(.clipboardArrived) }
        )
        let server = BridgeServer(
            store: KeychainStore(), mirror: mirror, icons: icons, displayAwake: screen.awake,
            screenLocked: !screen.unlocked,
            autoLock: DepartureLock(
                enabled: MacSwitches.autoLock && ScreenLock.available, delayMinutes: MacSwitches.autoLockMinutes
            ),
            publish: { continuation.yield($0) },
            session: { sessionContinuation.yield($0) }, clipboard: { clipContinuation.yield($0) }
        )
        slot.set(server)
        self.server = server
        self.reconciler = reconciler
        self.clicks = clicks
        self.icons = icons
        self.screen = screen
        self.clipboard = clipboard
        router = NotificationRouter(mirror: mirror, clicks: clicks)
        let (commands, commandContinuation) = AsyncStream.makeStream(of: PairingCommand.self)
        pairingCommands = commandContinuation
        let (autoLocks, autoLockContinuation) = AsyncStream.makeStream(
            of: DepartureLock.self, bufferingPolicy: .bufferingNewest(1)
        )
        autoLockSettings = autoLockContinuation
        #if DEBUG
        bridgectl = BridgectlServer(
            status: { await server.currentStatus() }, mirror: { await mirror.entries() },
            reconciler: { await reconciler.machine }, clipboard: { await clipboard.snapshot() }
        )
        bridgectl.start()
        #endif
        Task { [weak self] in
            for await status in updates {
                self?.show(status)
            }
        }
        Task {
            for await event in sessions {
                switch event {
                case .phoneSwitches(let clipboardFromMac):
                    clipboard.phoneSwitch(clipboardFromMac: clipboardFromMac)
                case .established:
                    clipboard.sessionStarted()
                case .synced:
                    reconciler.sessionConnected()
                case .ended:
                    reconciler.sessionEnded()
                    clipboard.sessionEnded()
                case .bluetooth(let linked):
                    reconciler.bluetoothChanged(linked: linked)
                    clipboard.bluetoothChanged(linked: linked)
                }
            }
        }
        Task {
            for await command in commands {
                switch command {
                case .start: await server.startPairing()
                case .enterCode(let code): await server.enterCode(code)
                case .dismiss: await server.dismissPairing()
                }
            }
        }
        Task {
            for await locked in locks {
                await server.screenLockChanged(locked: locked)
            }
        }
        Task {
            for await setting in autoLocks {
                await server.configureAutoLock(enabled: setting.enabled, delayMinutes: setting.delayMinutes)
            }
        }
        Task {
            for await clip in clips {
                clipboard.apply(clip)
            }
        }
        Task {
            for await report in reports {
                await server.mirrorReported(report)
                reconciler.mirroredChanged(report.mirrored)
            }
        }
        Task { await server.start() }
    }

    // The server publishes on every GATT frame and state-sync. No view shows that traffic (bridgectl
    // reads the server's own status), so it is dropped here and an otherwise unchanged status is not
    // assigned at all: the menu, the menu-bar icon and the pairing window are not redrawn per frame.
    private func show(_ published: BridgeStatus) {
        var shown = published
        shown.lastGattSent = nil
        shown.lastGattReceived = nil
        shown.lastStateSync = nil
        if shown != status { status = shown }
        if shown.menuBar != menuBar { menuBar = shown.menuBar }
    }

    var isPaired: Bool { status.peerFingerprint != nil }

    var hasStoredPairing: Bool { isPaired || status.pairingUnusable != nil }

    func setClipboardToPhone(_ on: Bool) {
        clipboardToPhone = on
        MacSwitches.save(clipboardToPhone: on)
        clipboard.macSwitch(sendsClips: on)
    }

    func setAutoLock(_ on: Bool) {
        autoLock = on
        saveAutoLock()
    }

    func setAutoLockMinutes(_ minutes: Int) {
        autoLockMinutes = minutes
        saveAutoLock()
    }

    private func saveAutoLock() {
        MacSwitches.save(autoLock: autoLock, minutes: autoLockMinutes)
        autoLockSettings.yield(DepartureLock(enabled: autoLock && canLockScreen, delayMinutes: autoLockMinutes))
    }

    func startPairing() {
        pairingCommands.yield(.start)
    }

    func enterCode(_ code: String) {
        pairingCommands.yield(.enterCode(code))
    }

    // SwiftUI may deliver the disappearance of a window's previous content after the appearance of
    // the next, so the ceremony ends only once no appearance of the pairing window is left.
    func pairingWindowAppeared() {
        pairingWindowAppearances += 1
        log.debug("pairing window appeared, appearances \(self.pairingWindowAppearances)")
        startPairing()
    }

    func pairingWindowDisappeared() {
        pairingWindowAppearances = max(0, pairingWindowAppearances - 1)
        log.debug("pairing window disappeared, appearances \(self.pairingWindowAppearances)")
        if pairingWindowAppearances == 0 { pairingCommands.yield(.dismiss) }
    }

    func unpair() {
        Task { await server.unpair() }
    }

    #if DEBUG
    func requestSync() {
        Task { await server.requestSync() }
    }

    func sendSignal(_ signal: Signal) {
        Task { await server.sendSignal(signal) }
    }
    #endif
}

nonisolated private enum PairingCommand: Sendable {
    case start
    case enterCode(String)
    case dismiss
}

nonisolated private final class ServerSlot: Sendable {
    private let value = Mutex<BridgeServer?>(nil)

    var server: BridgeServer? { value.withLock { $0 } }

    func set(_ server: BridgeServer) {
        value.withLock { $0 = server }
    }
}
