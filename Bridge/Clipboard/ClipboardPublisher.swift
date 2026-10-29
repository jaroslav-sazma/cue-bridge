import AppKit
import os

nonisolated struct ClipRecord: Equatable, Sendable {
    enum Direction: String, Sendable {
        case macToPhone = "mac-to-phone"
        case phoneToMac = "phone-to-mac"
    }

    var direction: Direction
    var wireType: String
    var bytes: Int
    var sensitive: Bool
    var announce: Bool
    var at: Date
}

nonisolated struct ClipboardSnapshot: Sendable {
    var machine: ClipboardPublisherMachine
    var accessBehavior: String
    var changeCount: Int?
    var lastSent: ClipRecord?
    var lastReceived: ClipRecord?
    var lastSkip: ClipSkip?
    var lastSkipAt: Date?
    var tombstones: Int
}

// Carries out ClipboardPublisherMachine and applies the phone's clips; both share one echo state.
// The display and lock events are ScreenObserver's callbacks, and the only scheduled work is the
// poll while the machine is armed, its waits stretched by IdlePacer while the user gives no input.
// Disarming cancels it, so nothing is left scheduled. Clip text lives only for the length of one
// pass or one write; what is kept is digests and metadata.
final class ClipboardPublisher {
    private static let interval = Duration.seconds(ClipboardPublisherMachine.intervalSeconds)
    private static let concealed = NSPasteboard.PasteboardType(ClipboardLimits.concealedType)

    private let pasteboard = NSPasteboard.general
    private let deliver: @Sendable (ClipboardEncoding) async -> OutboundResult
    private let signalPending: @Sendable () async -> Bool
    private let announce: () -> Void
    private let idle: () -> Duration?
    private let log = Logger(subsystem: "app.cue.bridge", category: "clipboard")
    private var machine: ClipboardPublisherMachine
    private var echo = ClipboardEcho()
    private var timer: Task<Void, Never>?
    private var passing = false
    private var reportedIdle: ClipboardPublisherMachine.Idle?
    private var lastChangeCount: Int?
    // A clip that found no way to the phone — no signal path, or only the Bluetooth link and too
    // large for a BLE frame — is read again at the next arming or session start, not on every poll,
    // and then goes with its age.
    private var debt: ClipboardDebt?
    private var lastSent: ClipRecord?
    private var lastReceived: ClipRecord?
    private var lastSkip: (reason: ClipSkip, at: Date)?

    init(
        screen: ScreenObserver, phoneTakesClips: Bool, macSendsClips: Bool,
        deliver: @escaping @Sendable (ClipboardEncoding) async -> OutboundResult,
        signalPending: @escaping @Sendable () async -> Bool, announce: @escaping () -> Void,
        idle: @escaping () -> Duration? = InputIdle.duration
    ) {
        self.deliver = deliver
        self.signalPending = signalPending
        self.announce = announce
        self.idle = idle
        machine = ClipboardPublisherMachine(
            screenAwake: screen.awake, unlocked: screen.unlocked, phoneTakesClips: phoneTakesClips,
            macSendsClips: macSendsClips
        )
        reportedIdle = machine.idle
        log.info(
            "clipboard publisher ready: pasteboard access \(Self.describe(NSPasteboard.general.accessBehavior), privacy: .public); no timer scheduled"
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

    func sessionStarted() {
        handle(.sessionStarted)
    }

    func sessionEnded() {
        handle(.sessionEnded)
    }

    func bluetoothChanged(linked: Bool) {
        handle(.bluetooth(linked: linked))
    }

    func phoneSwitch(clipboardFromMac: Bool) {
        guard clipboardFromMac != machine.phoneTakesClips else { return }
        log.info("phone takes clips from the Mac: \(clipboardFromMac ? "yes" : "no", privacy: .public)")
        handle(.phone(clipboardFromMac: clipboardFromMac))
    }

    // What was copied while the switch was off stays on the Mac: switching on counts the pasteboard
    // as already seen, where an ordinary arming would send it.
    func macSwitch(sendsClips: Bool) {
        guard sendsClips != machine.macSendsClips else { return }
        log.info("this Mac sends clips to the phone: \(sendsClips ? "yes" : "no", privacy: .public)")
        if sendsClips {
            lastChangeCount = pasteboard.changeCount
        } else {
            debt = nil
        }
        handle(.mac(sendsClips: sendsClips))
    }

    // Applied whether or not the Mac is locked: the user pastes after unlocking. The tombstone goes
    // in before the write, so the change the write causes is already an echo.
    func apply(_ clip: IncomingClip) {
        let bytes = clip.text.utf8.count
        guard ClipboardLimits.fits(clip.text) else {
            log.info("clipboard not applied: too-large bytes=\(bytes)")
            return
        }
        echo.applied(clip.text, at: .now)
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(clip.text, forType: .string)
        if clip.sensitive { item.setData(Data(), forType: Self.concealed) }
        guard pasteboard.writeObjects([item]) else {
            log.error("clipboard not applied: the pasteboard refused the write")
            return
        }
        lastReceived = ClipRecord(
            direction: .phoneToMac, wireType: "clipboard-set", bytes: bytes, sensitive: clip.sensitive,
            announce: clip.announce, at: .now
        )
        log.info("clipboard applied sensitive=\(clip.sensitive) announce=\(clip.announce) bytes=\(bytes)")
        if clip.announce { announce() }
    }

    func snapshot() -> ClipboardSnapshot {
        ClipboardSnapshot(
            machine: machine, accessBehavior: Self.describe(pasteboard.accessBehavior), changeCount: lastChangeCount,
            lastSent: lastSent, lastReceived: lastReceived, lastSkip: lastSkip?.reason, lastSkipAt: lastSkip?.at,
            tombstones: echo.liveTombstones(at: .now)
        )
    }

    // The access behavior is read again at every event, since System Settings tells nobody when the
    // user changes it.
    private func handle(_ event: ClipboardPublisherMachine.Event) {
        let effects = machine.handle(.access(denied: pasteboard.accessBehavior == .alwaysDeny))
        carryOut(effects + machine.handle(event))
    }

    private func carryOut(_ effects: [ClipboardPublisherMachine.Effect]) {
        var disarmed = false
        for effect in effects {
            switch effect {
            case .arm:
                arm()
            case .disarm(let idle):
                timer?.cancel()
                timer = nil
                disarmed = true
                // The phone would drop what it owes anyway.
                if idle == .phoneDeclines { debt = nil }
                log.info("clipboard publisher disarmed: \(idle.rawValue, privacy: .public); no timer scheduled")
            case .pass:
                rereadOwed()
                Task { await pass("session") }
            }
        }
        let idle = machine.armed ? nil : machine.idle
        if let idle, idle != reportedIdle, !disarmed {
            log.info("clipboard publisher idle: \(idle.rawValue, privacy: .public); no timer scheduled")
        }
        reportedIdle = idle
    }

    private func arm() {
        timer?.cancel()
        let idle = idle
        let log = log
        timer = Task { [weak self] in
            var pacer = IdlePacer(interval: Self.interval, start: .now)
            while !Task.isCancelled {
                try? await Task.sleep(for: pacer.wait, tolerance: pacer.wait / 2, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                guard pacer.fire(at: .now, idle: idle()) else {
                    let next = pacer.wait / .seconds(1)
                    log.debug("clipboard poll skipped: no input since the last pass, next in \(next, format: .fixed(precision: 0)) s")
                    continue
                }
                await self.pass("poll")
            }
        }
        log.info(
            "clipboard publisher armed: every \(ClipboardPublisherMachine.intervalSeconds) s, tolerance half of it, up to \(IdlePacer.stretch)× while no input"
        )
        rereadOwed()
        Task { await pass("arm") }
    }

    private func rereadOwed() {
        guard debt != nil else { return }
        lastChangeCount = nil
    }

    // Only a changed changeCount is read, and a marked clip never past its types.
    private func pass(_ origin: String) async {
        guard machine.armed, !passing else { return }
        passing = true
        defer { passing = false }
        let count = pasteboard.changeCount
        log.debug("clipboard poll (\(origin, privacy: .public)): changeCount \(count)")
        guard count != lastChangeCount else { return }
        guard pasteboard.accessBehavior != .alwaysDeny else {
            carryOut(machine.handle(.access(denied: true)))
            return
        }
        lastChangeCount = count
        let now = ContinuousClock.now
        let owed = debt?.changeCount == count ? debt : nil
        debt = nil
        if let owed, owed.expired(at: now) {
            log.info("clipboard debt forgotten: older than \(ClipboardDebt.lifetime / .seconds(60), format: .fixed(precision: 0)) min")
            return
        }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let clip = PasteboardClip(types: types) { pasteboard.string(forType: .string) }
        let decision: ClipDecision
        do {
            decision = try echo.decide(clip, at: now, ageMs: owed?.ageMs(at: now))
        } catch {
            log.error("clipboard not sent: the clip could not be encoded")
            return
        }
        switch decision {
        case .skip(let reason):
            lastSkip = (reason, .now)
            log.info("clipboard not sent: \(reason.rawValue, privacy: .public)")
        case .send(let text, let encoding):
            let bytes = text.utf8.count
            switch await deliver(encoding) {
            case .sent:
                echo.sent(text)
                lastSent = ClipRecord(
                    direction: .macToPhone, wireType: encoding.wireType, bytes: bytes, sensitive: false, announce: false,
                    at: .now
                )
                let age = owed.map { " ageMs=\($0.ageMs(at: now))" } ?? ""
                log.info("clipboard sent: \(encoding.wireType, privacy: .public) bytes=\(bytes)\(age, privacy: .public)")
            case .noSession:
                await owe(ClipboardDebt(changeCount: count, observedAt: owed?.observedAt ?? now, signalled: owed?.signalled ?? false))
            case .notSent:
                log.error("clipboard not sent: the frame could not be sealed")
            }
        }
    }

    // Spec, `clipboard-pending`: told once per debt, and only over a confirmed Bluetooth link, which
    // the server checks; without one the next arming tries again.
    private func owe(_ owed: ClipboardDebt) async {
        var owed = owed
        guard machine.bluetoothUp else {
            debt = owed
            log.info("clipboard not sent: no session or Bluetooth link")
            return
        }
        if !owed.signalled {
            owed.signalled = await signalPending()
        }
        debt = owed
        let told = owed.signalled ? "the phone was told over Bluetooth" : "the phone could not be told"
        log.info("clipboard not sent: it needs a session, read again when one starts; \(told, privacy: .public)")
    }

    private static func describe(_ behavior: NSPasteboard.AccessBehavior) -> String {
        switch behavior {
        case .default: "default"
        case .ask: "ask"
        case .alwaysAllow: "alwaysAllow"
        case .alwaysDeny: "alwaysDeny"
        @unknown default: "unknown(\(behavior.rawValue))"
        }
    }
}
