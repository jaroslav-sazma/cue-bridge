import CryptoKit
import Foundation
import Network
import os

// `established` comes with the hello, `synced` with the session's first active-set, which a Send to
// Mac connection never sends. `bluetooth` follows a GATT subscription confirmed as the paired
// phone's, the other half of the signal path; a bare subscription never counts. `phoneSwitches`
// comes ahead of `established` with what the session's hello said, and with off when the pairing
// changes.
nonisolated enum SessionEvent: Sendable {
    case phoneSwitches(clipboardFromMac: Bool)
    case established
    case synced
    case ended
    case bluetooth(linked: Bool)
}

nonisolated struct IncomingClip: Sendable {
    var text: String
    var sensitive: Bool
    var announce: Bool
}

// Runs on its own serial queue: the Network framework calls back on that queue, and the handlers
// enter the actor with assumeIsolated, so every event is handled in arrival order.
actor BridgeServer {
    private static let stepTimeout = LinkMachine.stepTimeout
    private static let pairingModeLifetime = Duration.seconds(120)
    private static let confirmationLifetime = Duration.seconds(120)
    private static let closeGrace = DispatchTimeInterval.seconds(2)
    // How long a lock is given to show in the session dictionary before the answer reads it.
    private static let lockAnswerDelay = Duration.milliseconds(200)
    private static let portKey = "listenerPort"

    private let queue = DispatchSerialQueue(label: "app.cue.bridge.server")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let store: any BridgeStore
    private let sequenceFile: SequenceFile
    private let host: String?
    private let mirror: NotificationMirror
    private let icons: IconCache
    private let gate = TrustGate()
    private let publish: @Sendable (BridgeStatus) -> Void
    private let session: @Sendable (SessionEvent) -> Void
    private let clipboard: @Sendable (IncomingClip) -> Void
    private let log = Logger(subsystem: "app.cue.bridge", category: "transport")
    private let protocolLog = Logger(subsystem: "app.cue.bridge", category: "protocol")

    private var status = BridgeStatus() {
        didSet { if status != oldValue { publish(status) } }
    }
    private var identity: LocalIdentity?
    // Both set or both nil: a key whose sequence state cannot be read is never loaded at all.
    private var pairing: PairingRecord?
    private var sequences: SequenceBook?
    private var instanceName: String?

    private var listener: NWListener?
    private var listenerGeneration = 0
    private var links: [Int: Link] = [:]
    private var nextLinkID = 0
    private var slots = SessionSlots()
    private var coalescer = SyncCoalescer()
    private var summons: SummonGate
    private var ble: BlePeripheral?
    // A subscriber may be summoned; only a confirmed one is the phone being nearby.
    private var gattSubscribed = false
    private var phoneLinked = false
    private var seenServiceReadds = 0
    private var pendingReplyTexts = PendingReplyTexts()
    private var screenLocked: Bool
    private var departure: DepartureLock
    private var departureTimer: Task<Void, Never>?

    private var ceremony: MacPairingCeremony?
    private var pairingModeTimer: Task<Void, Never>?
    private var ceremonyTimer: Task<Void, Never>?
    private var lastPairingModeExpired = false

    init(
        store: any BridgeStore, sequenceFile: SequenceFile = .standard, host: String? = HostIdentity.hardwareUUID(),
        mirror: NotificationMirror, icons: IconCache, displayAwake: Bool, screenLocked: Bool, autoLock: DepartureLock,
        publish: @escaping @Sendable (BridgeStatus) -> Void, session: @escaping @Sendable (SessionEvent) -> Void,
        clipboard: @escaping @Sendable (IncomingClip) -> Void
    ) {
        summons = SummonGate(displayAwake: displayAwake)
        self.screenLocked = screenLocked
        departure = autoLock
        self.store = store
        self.sequenceFile = sequenceFile
        self.host = host
        self.mirror = mirror
        self.icons = icons
        self.publish = publish
        self.session = session
        self.clipboard = clipboard
    }

    func start() {
        if host == nil { log.error("this Mac's hardware UUID cannot be read: no pairing can be loaded or made") }
        do {
            switch PairingOpening.open(try store.loadPairing(on: host), sequences: sequenceFile) {
            case .none:
                break
            case .usable(let record, let book):
                pairing = record
                sequences = book
            case .unusable(let reason, let detail):
                log.error("pairing unusable, \(reason.rawValue, privacy: .public): \(detail, privacy: .public)")
                status.pairingUnusable = reason
            }
        } catch {
            report(error, "Loading the pairing")
        }
        gate.setPin(pairing?.peerFingerprint)
        status.peerFingerprint = pairing?.peerFingerprint
        if pairing != nil { ensureListener() }
        refreshBle()
    }

    func currentStatus() -> BridgeStatus {
        status
    }

    func mirrorReported(_ report: NotificationMirror.Report) {
        status.mirroredCount = report.mirrored
        if report.resetsSync { status.lastStateSync = nil }
        if let sync = report.sync { status.lastStateSync = sync }
    }

    // MARK: Pairing

    func startPairing() {
        if let ceremony, ceremony.isActive { return }
        guard host != nil else {
            status.pairing = .failed("This Mac's hardware UUID cannot be read, so a pairing could not be bound to it.")
            return
        }
        guard let identity = loadIdentity() else {
            status.pairing = .failed("The bridge identity is not available. \(status.storageError ?? "")")
            return
        }
        lastPairingModeExpired = false
        ceremony = MacPairingCeremony(fpMac: identity.fingerprint)
        gate.setPairingMode(true)
        status.pairing = .preparing
        log.info("pairing mode on")
        if listener == nil { ensureListener() } else { advertise() }
        refreshBle()
        openPairingModeIfReady()
    }

    func enterCode(_ typed: String) {
        drive { $0.enterCode(typed) }
        if case .confirming(_, false, let rejected) = ceremony?.phase, rejected > 0 {
            log.info("typed code does not match the phone's (\(rejected) so far)")
        }
    }

    func dismissPairing() {
        if ceremony?.isActive == true {
            drive { $0.cancel() }
        }
        status.pairing = .idle
    }

    func unpair() {
        do {
            try store.wipePairing()
            try sequenceFile.delete()
        } catch {
            report(error, "Unpairing")
            return
        }
        pairing = nil
        sequences = nil
        status.pairingUnusable = nil
        pendingReplyTexts.forgetAll()
        forgetPhone()
        gate.setPin(nil)
        status.peerFingerprint = nil
        status.lastStateSync = nil
        status.lastGattSent = nil
        status.lastGattReceived = nil
        // Ahead of the session end, which would otherwise post what is held for an icon.
        mirror.submit(.removeAll)
        for link in links.values where link.stage == .session || link.transport == .l2cap {
            close(link)
        }
        if ceremony == nil { stopListener() }
        moveDeparture { $0.forget() }
        ble?.revokeConfirmations()
        refreshBle()
        log.info("unpaired")
    }

    // Pairing mode counts from the moment a phone can reach the listener.
    private func openPairingModeIfReady() {
        guard ceremony?.phase == .waiting, pairingModeTimer == nil, case .ready(let port) = status.listener else {
            return
        }
        status.pairing = .waiting(expiresAt: .now.addingTimeInterval(120))
        protocolLog.debug("pairing mode open on port \(port)")
        pairingModeTimer = Task {
            try? await Task.sleep(for: Self.pairingModeLifetime, tolerance: .seconds(1), clock: .continuous)
            guard !Task.isCancelled else { return }
            self.pairingModeExpired()
        }
    }

    private func pairingModeExpired() {
        guard ceremony?.phase == .waiting else { return }
        lastPairingModeExpired = true
        log.info("pairing mode expired, no phone asked")
        drive { $0.timeout() }
    }

    private func armCeremonyTimer(_ length: Duration, waitingFor what: String) {
        ceremonyTimer?.cancel()
        ceremonyTimer = Task {
            try? await Task.sleep(for: length, tolerance: .seconds(1), clock: .continuous)
            guard !Task.isCancelled else { return }
            self.ceremonyTimedOut(what)
        }
    }

    private func ceremonyTimedOut(_ what: String) {
        log.info("pairing timed out waiting for \(what, privacy: .public)")
        drive { $0.timeout() }
    }

    private func failCeremony(_ message: String) {
        drive { $0.cancel() }
        status.pairing = .failed(message)
    }

    private func drive(_ step: (inout MacPairingCeremony) -> [PairingEffect]) {
        guard var ceremony else { return }
        let effects = step(&ceremony)
        self.ceremony = ceremony
        let link = slots.ceremony.flatMap { links[$0] }
        for effect in effects {
            switch effect {
            case .send(let message):
                if let link { send(message, on: link) }
            case .armStepTimer:
                armCeremonyTimer(Self.stepTimeout, waitingFor: "pair-reveal")
            case .armConfirmationTimer:
                armCeremonyTimer(Self.confirmationLifetime, waitingFor: "the code and both confirmations")
            case .commit(let fingerprint, let kBle):
                commit(PairingRecord(peerFingerprint: fingerprint, kBle: kBle))
            case .close:
                if let link { close(link) }
            }
        }
        switch ceremony.phase {
        case .waiting:
            break
        case .revealing:
            status.pairing = .verifying
        case .confirming(_, true, _):
            status.pairing = .codeAccepted
        case .confirming(_, false, let rejected):
            status.pairing = .enteringCode(rejected: rejected)
        case .ended(let end):
            finishCeremony(end)
        }
    }

    // The fresh sequence state goes first and belongs to the new key only, so a save that fails
    // part-way leaves whatever key the Keychain kept without state of its own: unusable, never
    // counting from zero again.
    private func commit(_ record: PairingRecord) {
        guard let host else {
            status.pairing = .failed("This Mac's hardware UUID cannot be read, so a pairing could not be bound to it.")
            return
        }
        let fresh = SequenceState(fresh: record.kBle)
        do {
            try sequenceFile.save(fresh, durable: true)
        } catch {
            report(error, "Saving the sequence state")
            status.pairing = .failed("The pairing could not be saved. \(error)")
            return
        }
        do {
            try store.savePairing(record, on: host)
        } catch {
            report(error, "Saving the pairing")
            status.pairing = .failed("The pairing could not be saved. \(error)")
            if pairing != nil { dropUnusablePairing() }
            return
        }
        if let id = slots.session, let link = links[id] { close(link) }
        // Keyed under the previous K_ble, if any.
        for link in links.values where link.transport == .l2cap {
            close(link)
        }
        pairing = record
        sequences = SequenceBook(fresh)
        status.pairingUnusable = nil
        pendingReplyTexts.forgetAll()
        forgetPhone()
        gate.setPin(record.peerFingerprint)
        status.peerFingerprint = record.peerFingerprint
        status.lastStateSync = nil
        status.lastGattSent = nil
        status.lastGattReceived = nil
        status.pairing = .committed(macFingerprint: identity?.fingerprint)
        log.info("pairing committed, peer \(String(record.peerFingerprint.hex.prefix(8)), privacy: .public)")
        moveDeparture { $0.forget() }
        ble?.revokeConfirmations()
        refreshBle()
    }

    private func finishCeremony(_ end: PairingEnd) {
        pairingModeTimer?.cancel()
        pairingModeTimer = nil
        ceremonyTimer?.cancel()
        ceremonyTimer = nil
        gate.setPairingMode(false)
        if let id = slots.releaseCeremony(), let link = links[id] { link.machine.ceremonyEnded() }
        ceremony = nil
        if case .aborted(let reason) = end {
            status.pairing = .aborted(Self.describe(reason))
            log.info("pairing aborted: \(String(describing: reason), privacy: .public)")
        }
        refreshConnectionStatus()
        if pairing == nil { stopListener() } else { advertise() }
        refreshBle()
    }

    private static func describe(_ abort: PairingAbort) -> String {
        switch abort {
        case .sent(.sasMismatch): "The codes did not match."
        case .sent(.cancelled), .sent(.busy), .cancelledBeforeRequest: "Pairing was cancelled."
        case .sent(.timeout): "The pairing was not completed in time."
        case .sent(.protocolError):
            "The phone sent something invalid, or a key other than the one it committed to. Nothing was paired."
        case .received(.sasMismatch): "The phone reported that the codes differ."
        case .received(.cancelled), .received(.busy): "Pairing was cancelled on the phone."
        case .received(.timeout): "The phone timed out."
        case .received(.protocolError): "The phone reported a protocol error."
        case .expired: "No phone asked to pair in time."
        case .connectionLost: "The connection to the phone was lost."
        }
    }

    // MARK: Session

    private var sessionLink: Link? {
        slots.session.flatMap { links[$0] }
    }

    // A signal needs a pairing. The order of the carriers is SignalPaths'.
    private var paths: SignalPaths {
        let machine = gattSubscribed ? ble?.machine : nil
        return SignalPaths(
            phonePayload: machine?.payload(for: .phone),
            summonPayload: machine?.payload(for: .anyone),
            sessionUp: sessionLink != nil
        )
    }

    @discardableResult
    func requestSync() -> Bool {
        guard let link = sessionLink else { return false }
        requestSync(on: link)
        return true
    }

    private func requestSync(on link: Link) {
        if coalescer.requested() {
            send(.syncRequest, on: link)
        } else {
            protocolLog.debug("sync-request outstanding on conn=\(link.id), one more follows the active-set")
        }
    }

    private func forgetPhone() {
        PhoneSwitches.forget()
        session(.phoneSwitches(clipboardFromMac: false))
        summons.pairingChanged()
    }

    // A doorbell asks for the set on the session; without one it summons the phone over GATT.
    private func doorbellRang() -> Bool {
        ask(for: .doorbell)
    }

    func screenSlept() {
        summons.displaySlept()
    }

    // The Mac's sleep ends the Bluetooth links, whether CoreBluetooth reports that before the sleep
    // or at wake; neither is the phone leaving.
    func systemWillSleep() {
        moveDeparture { $0.forget() }
    }

    // Spec, `sync-request`: the mirror may have drifted while the display slept, and a session from
    // before the sleep may be dead; a request on it is what finds that out. It also stands for every
    // summon the sleep held back.
    func screenWoke() {
        let waited = summons.displayWoke()
        if waited > 0 { protocolLog.info("display awake: \(waited) summons held back while it slept, one ask follows") }
        ask(for: .wake)
    }

    // True when a summon went out over GATT.
    @discardableResult
    private func ask(for reason: SummonReason) -> Bool {
        switch coalescer.ask(sessionUp: sessionLink != nil) {
        case .send:
            if let link = sessionLink {
                protocolLog.debug("\(reason.rawValue, privacy: .public): sync-request on conn=\(link.id)")
                send(.syncRequest, on: link)
            }
            return false
        case .folded:
            protocolLog.debug("\(reason.rawValue, privacy: .public): sync-request outstanding, one more follows the active-set")
            return false
        case .summon:
            return summon(for: reason)
        }
    }

    // The sync-request frame over GATT makes the phone open a session whose first active-set
    // answers it. Not coalesced: the phone makes one connection attempt per summon, so each doorbell
    // is another chance, and it ignores a summon while its visit is under way. The phone never sends
    // one, so nothing here can answer a summon with a summon. SummonGate holds summons back while
    // the display sleeps and right after a sync.
    private func summon(for reason: SummonReason) -> Bool {
        guard sessionLink == nil else { return false }
        guard paths.summonPayload != nil else {
            protocolLog.debug("\(reason.rawValue, privacy: .public) with no session and no Bluetooth link: nothing can ask for the set")
            return false
        }
        switch summons.ask(reason, at: .now) {
        case .deferred:
            protocolLog.info("summon for the \(reason.rawValue, privacy: .public) held back: display asleep")
            return false
        case .recentSync:
            protocolLog.info("summon for the \(reason.rawValue, privacy: .public) skipped: a state-sync came in minutes ago and the display has not slept since")
            return false
        case .summon:
            protocolLog.debug("summon over gatt for the \(reason.rawValue, privacy: .public)")
            return transmit(.syncRequest) == .sent
        }
    }

    @discardableResult
    func sendSignal(_ signal: Signal) -> Bool {
        transmit(signal) == .sent
    }

    // The route is decided first, so a signal that cannot leave spends no seq. The block a seq comes
    // from is persisted before the frame leaves, so no seq is ever used twice under one key, over
    // either carrier.
    private func transmit(_ signal: Signal, via chosen: SignalCarrier? = nil) -> OutboundResult {
        guard let pairing else { return .noSession }
        let carrier: SignalCarrier
        do {
            guard let route = try chosen ?? paths.carrier(for: signal) else { return .noSession }
            carrier = route
        } catch {
            log.error("signal \(signal.name, privacy: .public) could not be encoded")
            return .notSent
        }
        guard let seq = nextOutgoingSeq() else { return .notSent }
        let frame: Data
        do {
            frame = try SignalFrame.seal(
                type: signal.code, seq: seq, plaintext: signal.plaintext(), key: SymmetricKey(data: pairing.kBle),
                direction: .macToPhone
            )
        } catch {
            log.error("signal could not be sealed: \(String(describing: error), privacy: .public)")
            return .notSent
        }
        switch carrier {
        case .tcp:
            guard let link = sessionLink else { return .noSession }
            protocolLog.debug(
                "send signal \(signal.name, privacy: .public) seq=\(seq) k=\(signal.keyHash ?? "-", privacy: .public)"
            )
            send(.signal(frame: frame.base64EncodedString()), on: link)
        case .gatt:
            // Sent means handed to the stack. Only a summon goes to a subscriber not confirmed yet,
            // which may be a stranger that drops it: the log says which it was.
            let unconfirmed = ble?.machine.phoneLinked == true ? "" : ", subscriber not confirmed"
            guard ble?.notify(frame, to: signal.audience) == true else {
                protocolLog.info("signal \(signal.name, privacy: .public) seq=\(seq) not sent: the Bluetooth link just went")
                return .noSession
            }
            protocolLog.debug(
                "send signal \(signal.name, privacy: .public) seq=\(seq) k=\(signal.keyHash ?? "-", privacy: .public) via gatt\(unconfirmed, privacy: .public)"
            )
            status.lastGattSent = BridgeStatus.GattTraffic(type: signal.name, at: .now)
        }
        return .sent
    }

    private func nextOutgoingSeq() -> UInt32? {
        guard var book = sequences else { return nil }
        if case .reserve(let reservation) = book.nextOutgoing() {
            do {
                try sequenceFile.save(reservation, durable: true)
            } catch {
                report(error, "Saving the sequence state")
                return nil
            }
            book.reserved(reservation)
            sequences = book
        }
        guard case .seq(let seq) = book.nextOutgoing() else {
            log.error("outgoing signal sequence exhausted; pair again")
            return nil
        }
        book.spend(seq)
        sequences = book
        return seq
    }

    // The Keychain may now hold either key, and neither has state of its own: the next start finds
    // the same and reports it the same way.
    private func dropUnusablePairing() {
        pairing = nil
        sequences = nil
        forgetPhone()
        status.pairingUnusable = .sequenceState
        gate.setPin(nil)
        status.peerFingerprint = nil
        mirror.submit(.removeAll)
        for link in links.values where link.stage == .session || link.transport == .l2cap {
            close(link)
        }
        moveDeparture { $0.forget() }
        ble?.revokeConfirmations()
        refreshBle()
    }

    // The superseded session is closed first, which releases its slot and its coalescer state;
    // only then is the new one bound.
    private func establishSession(_ link: Link) {
        if let previous = slots.superseded(by: link.id), let old = links[previous] {
            send(.bye(reason: BridgeMessage.replaced), on: old)
            close(old)
        }
        slots.bindSession(link.id)
        coalescer.sessionStarted()
        refreshConnectionStatus()
        // Spec, `hello`: an absent switch means on.
        let clips = link.clipboardFromMac ?? true
        PhoneSwitches.save(clipboardFromMac: clips)
        session(.phoneSwitches(clipboardFromMac: clips))
        session(.established)
        log.info(
            "session \(link.id) established with \(link.endpoint, privacy: .public) over \(link.transport.rawValue, privacy: .public)"
        )
        sendLockState(via: .tcp)
    }

    // What the mirror sends on the user's behalf. With neither a session nor a subscriber over GATT
    // nothing leaves (`noSession`); `notSent` is a frame that could not be sealed or
    // encoded.
    func deliver(_ outbound: MirrorOutbound) -> OutboundResult {
        guard pairing != nil else { return .noSession }
        switch outbound {
        case .dismiss(let keyHash, let revision):
            return transmit(.dismiss(keyHash: keyHash, revision: revision))
        case .reply(let key, let text):
            let steps: [OutboundStep]?
            do {
                steps = try paths.plan(ReplyEncoding.plan(key: key, text: text))
            } catch {
                log.error("reply could not be encoded")
                return .notSent
            }
            return steps.map(carryOut) ?? .noSession
        }
    }

    // A clip too large for a BLE frame needs the session.
    func deliverClipboard(_ encoding: ClipboardEncoding) -> OutboundResult {
        guard pairing != nil else { return .noSession }
        let steps: [OutboundStep]?
        do {
            steps = try paths.plan(encoding)
        } catch {
            log.error("clipboard could not be encoded")
            return .notSent
        }
        return steps.map(carryOut) ?? .noSession
    }

    // Spec, frame types: only a confirmed subscriber hears that a clip waits; a stranger could not
    // fetch it anyway, and the phone is the one that opens the session.
    func sendClipboardPending() -> Bool {
        guard pairing != nil, sessionLink == nil, paths.phonePayload != nil else { return false }
        return transmit(.clipboardPending, via: .gatt) == .sent
    }

    private func carryOut(_ steps: [OutboundStep]) -> OutboundResult {
        for step in steps {
            switch step {
            case .signal(let signal, let carrier):
                let result = transmit(signal, via: carrier)
                guard result == .sent else { return result }
            case .message(let message):
                guard let link = sessionLink else { return .noSession }
                send(message, on: link)
            case .keepForNextSession(let message):
                let dropped = pendingReplyTexts.keep(message)
                if case .replyText(let key, _) = message {
                    protocolLog.info(
                        "reply-text k=\(Signal.keyHash(of: key), privacy: .public) waits for the next session (\(self.pendingReplyTexts.count) waiting)"
                    )
                }
                if dropped > 0 { log.info("\(dropped) older waiting reply-text dropped past the cap") }
            }
        }
        return .sent
    }

    // Spec, `reply-text`: "otherwise on the next one" — here the first session that sends its
    // active-set, which a Send to Mac connection never does.
    private func sendWaitingReplyTexts(on link: Link) {
        let waiting = pendingReplyTexts.count
        let fresh = pendingReplyTexts.takeAll()
        if fresh.count < waiting {
            protocolLog.info("\(waiting - fresh.count) waiting reply-text dropped: their answer was overdue")
        }
        for message in fresh {
            if case .replyText(let key, _) = message {
                protocolLog.info("reply-text k=\(Signal.keyHash(of: key), privacy: .public) sent on conn=\(link.id), it waited for a session")
            }
            send(message, on: link)
        }
    }

    // The connect pass waits for the session's first active-set: a dismiss sent before it would
    // reach a phone whose ledger is still empty. The mirror runs its commands in order, so the pass
    // comes after this sync is applied.
    private func receivedInSession(_ message: BridgeMessage, on link: Link) {
        switch message {
        case .activeSet(let notifications):
            protocolLog.info("state-sync: \(notifications.count) notifications")
            summons.synced(at: .now)
            let first = !link.stateSynced
            if first {
                link.stateSynced = true
                mirror.submit(.sessionStarted)
            }
            mirror.submit(.sync(notifications, requested: requestIcons(for: notifications, on: link)))
            if first {
                session(.synced)
                sendWaitingReplyTexts(on: link)
            }
            if coalescer.activeSetReceived() {
                protocolLog.debug("doorbells rang while waiting, one more sync-request")
                send(.syncRequest, on: link)
            }
        case .notifDetail(let info):
            mirror.submit(.upsert(info, requested: requestIcons(for: [info], on: link)))
        case .iconData(let hash, let png):
            receivedIcon(hash: hash, png: png, on: link)
        case .signal(let frame):
            receivedSignal(frame, on: link)
        case .clipboardSet(let text, let sensitive, let announce, _):
            clipboard(IncomingClip(text: text, sensitive: sensitive, announce: announce))
        default:
            protocolLog.debug("recv \(message.type, privacy: .public) not handled in this phase")
        }
    }

    private func requestIcons(for notifications: [NotificationInfo], on link: Link) -> Set<String> {
        let icons = icons
        let hashes = link.iconRequests.toRequest(notifications, isCached: { icons.contains($0) })
        for hash in hashes {
            send(.iconGet(hash: hash), on: link)
        }
        return Set(hashes)
    }

    private func receivedIcon(hash: String, png: Data, on link: Link) {
        guard link.iconRequests.wasRequested(hash) else {
            protocolLog.debug("recv icon-data conn=\(link.id) not requested, ignored")
            return
        }
        guard IconHash.verifies(hash, png) else {
            protocolLog.info("recv icon-data conn=\(link.id) does not match its hash, discarded")
            mirror.submit(.iconFailed(hash: hash))
            return
        }
        do {
            try icons.store(png, hash: hash)
        } catch {
            log.error("icon could not be cached: \(error.localizedDescription, privacy: .public)")
            mirror.submit(.iconFailed(hash: hash))
            return
        }
        mirror.submit(.iconArrived(hash: hash))
    }

    private func receivedSignal(_ encoded: String, on link: Link) {
        guard pairing != nil, let frame = Data(base64Encoded: encoded) else {
            protocolLog.debug("recv signal dropped: no pairing or not base64")
            return
        }
        receivedFrame(frame, via: .tcp)
    }

    // The one intake for both carriers. The actor makes the check-and-advance of the shared incoming
    // seq atomic, so a frame is accepted at most once however it arrives. An accepted doorbell write
    // confirms its writer's subscription before the frame is acted on, so a doorbell that brings the
    // confirmation finds the phone already linked. Replays are dropped before this, so the answer to
    // a confirmation cannot loop.
    private func receivedFrame(_ frame: Data, via carrier: SignalCarrier, from central: UUID? = nil) {
        let via = carrier == .gatt ? " via gatt" : ""
        guard let pairing, var book = sequences else {
            protocolLog.debug("recv signal dropped\(via, privacy: .public): no pairing")
            return
        }
        var window = book.window
        let opened: OpenedSignal
        let interpretation: SignalInterpretation
        let intake = SignalIntake.take(frame, key: SymmetricKey(data: pairing.kBle), window: &window)
        switch intake {
        case .dropped(let rejection):
            protocolLog.debug("recv signal dropped\(via, privacy: .public): \(String(describing: rejection), privacy: .public)")
            return
        case .accepted(let accepted, let interpreted):
            opened = accepted
            interpretation = interpreted
        }
        let accepted = book.accepted(window)
        sequences = book
        do {
            try sequenceFile.save(accepted, durable: false)
        } catch {
            report(error, "Saving the sequence state")
        }
        if carrier == .gatt {
            status.lastGattReceived = BridgeStatus.GattTraffic(type: Signal.name(of: opened.type), at: .now)
        }
        let confirmed = central.map { ble?.received(intake, from: $0) == true } ?? false
        if confirmed {
            bluetoothChanged(confirmedBy: Signal.name(of: opened.type))
        }
        var summoned = false
        switch interpretation {
        case .valid(let signal):
            protocolLog.debug(
                "recv signal \(signal.name, privacy: .public) seq=\(opened.seq) k=\(signal.keyHash ?? "-", privacy: .public)\(via, privacy: .public)"
            )
            switch signal {
            case .notifPosted:
                summoned = doorbellRang()
            case .notifRemoved(let keyHash):
                mirror.submit(.remove(keyHash: keyHash))
            case .replyError(let keyHash, let reason):
                mirror.submit(.replyFailed(keyHash: keyHash, reason: reason))
            case .replyOk(let keyHash):
                mirror.submit(.replyConfirmed(keyHash: keyHash))
            case .lock:
                lockRequested(via: carrier)
            default:
                break
            }
        case .unknownType:
            protocolLog.debug("recv signal type \(opened.type) seq=\(opened.seq) unknown, ignored\(via, privacy: .public)")
        case .invalid:
            protocolLog.debug(
                "recv signal \(Signal.name(of: opened.type), privacy: .public) seq=\(opened.seq) invalid, ignored\(via, privacy: .public)"
            )
        }
        if confirmed { answerConfirmation(summoned: summoned) }
    }

    // Spec, GATT transport: a confirmation is answered over GATT at once, which is how the phone learns
    // that its Bluetooth peer is the paired Mac — with a summon while no session is up, so a phone that
    // came into range catches the mirror up even if nothing is posted, else with a ping. A confirming
    // doorbell may have summoned on its own; a summon held back is answered with a ping as well.
    private func answerConfirmation(summoned: Bool) {
        let summonedNow = sessionLink == nil && (summoned || summon(for: .confirmed))
        if !summonedNow, paths.phonePayload != nil {
            _ = transmit(.ping, via: .gatt)
        }
        sendLockState(via: .gatt)
    }

    // A record that opened on a central's own L2CAP channel is a frame that central wrote itself.
    private func recordsOpened(from central: UUID) {
        guard pairing != nil, ble?.authenticated(central) == true else { return }
        bluetoothChanged(confirmedBy: "l2cap record")
        answerConfirmation(summoned: false)
    }

    // MARK: Screen lock

    // Spec, frame types: a change goes to every confirmed subscriber and on the session alike.
    func screenLockChanged(locked: Bool) {
        screenLocked = locked
        sendLockState(via: .gatt)
        sendLockState(via: .tcp)
    }

    func configureAutoLock(enabled: Bool, delayMinutes: Int) {
        moveDeparture { $0.configure(enabled: enabled, delayMinutes: delayMinutes) }
    }

    // A carrier that is not up takes nothing, so no seq is spent on it.
    private func sendLockState(via carrier: SignalCarrier, locked: Bool? = nil) {
        guard pairing != nil else { return }
        switch carrier {
        case .gatt: guard paths.phonePayload != nil else { return }
        case .tcp: guard sessionLink != nil else { return }
        }
        _ = transmit(.lockState(locked: locked ?? screenLocked), via: carrier)
    }

    // Spec, frame types: every `lock` is answered with the state after the attempt, on the carrier it
    // came by while that is up. A short-lived connection sends its bye right behind the lock, so the
    // bye's close waits for the answer.
    private func lockRequested(via carrier: SignalCarrier) {
        let link = carrier == .tcp ? sessionLink : nil
        link?.lockAnswersOwed += 1
        let id = link?.id
        let locked = ScreenLock.isLocked() ?? screenLocked
        guard !locked, ScreenLock.available else {
            let why = locked ? "the screen is already locked" : "this Mac cannot lock its screen"
            protocolLog.info("lock changes nothing: \(why, privacy: .public)")
            answerLock(via: carrier, on: id)
            return
        }
        let log = protocolLog
        Task {
            await Self.lockScreen(log: log, reason: "the phone asked")
            try? await Task.sleep(for: Self.lockAnswerDelay, clock: .continuous)
            self.answerLock(via: carrier, on: id)
        }
    }

    private func answerLock(via carrier: SignalCarrier, on id: Int?) {
        let locked = ScreenLock.isLocked() ?? screenLocked
        let link = id.flatMap { links[$0] }
        let cameByIsUp = switch carrier {
        case .gatt: paths.phonePayload != nil
        case .tcp: link != nil && link === sessionLink
        }
        if cameByIsUp {
            sendLockState(via: carrier, locked: locked)
        } else if pairing != nil, let route = try? paths.carrier(for: .lockState(locked: locked)) {
            _ = transmit(.lockState(locked: locked), via: route)
        }
        guard let link else { return }
        link.lockAnswersOwed -= 1
        if link.lockAnswersOwed == 0, link.closeWhenAnswered { close(link) }
    }

    @MainActor
    private static func lockScreen(log: Logger, reason: String) {
        guard let result = ScreenLock.lock() else { return }
        log.info("screen lock asked for, \(reason, privacy: .public): result \(result)")
    }

    private func moveDeparture(_ change: (inout DepartureLock) -> Void) {
        let before = departure.deadline
        change(&departure)
        guard departure.deadline != before else { return }
        departureTimer?.cancel()
        departureTimer = nil
        guard let deadline = departure.deadline else {
            log.info("auto-lock disarmed")
            return
        }
        log.info("auto-lock armed: the phone left, locking in \(self.departure.delayMinutes) min")
        scheduleDeparture(at: deadline)
    }

    private func scheduleDeparture(at deadline: SuspendingClock.Instant) {
        departureTimer = Task {
            try? await Task.sleep(until: deadline, tolerance: .seconds(5), clock: .suspending)
            guard !Task.isCancelled else { return }
            self.departureDue()
        }
    }

    private func departureDue() {
        departureTimer = nil
        switch departure.fire(screenLocked: ScreenLock.isLocked() ?? screenLocked) {
        case nil:
            if let deadline = departure.deadline { scheduleDeparture(at: deadline) }
        case .alreadyLocked:
            log.info("auto-lock skipped: the screen is already locked")
        case .lock:
            let log = log
            Task { await Self.lockScreen(log: log, reason: "the phone left") }
        }
    }

    // MARK: Bluetooth

    // Enabled exactly while the listener has a reason to run: paired, or in pairing mode, where the
    // phone's companion-device association scans for the advertisement.
    private func refreshBle() {
        let enabled = pairing != nil || ceremony != nil
        if ble == nil {
            guard enabled else { return }
            ble = BlePeripheral(queue: queue) { event in
                self.assumeIsolated { $0.gatt(event) }
            }
        }
        ble?.configure(enabled: enabled, paired: pairing != nil)
    }

    private func gatt(_ event: GattEvent) {
        switch event {
        case .changed:
            bluetoothChanged()
        case .frame(let frame, let central):
            receivedFrame(frame, via: .gatt, from: central)
        case .channel(let pump):
            l2capOpened(pump)
        }
    }

    // A subscription counts only while paired; in pairing mode no frame could be sealed or opened
    // anyway. A summon may go to any subscriber; every other frame, and everything that stands for the
    // phone being nearby — the reconciler, the clipboard poll, the dismissal detection, the menu —
    // follows a confirmed one only.
    private func bluetoothChanged(confirmedBy reason: String? = nil) {
        let machine = ble?.machine ?? GattPeripheralMachine()
        status.bluetooth = Self.describe(machine)
        status.l2cap = machine.enabled ? machine.channel : .idle
        let paired = pairing != nil
        let linked = paired && machine.phoneLinked
        status.bluetoothPayload = paired ? machine.payload(for: .anyone) : nil
        status.bluetoothConfirmed = linked
        let radioOn = machine.enabled && machine.radio == .poweredOn
        let droppedByMac = machine.serviceReadds != seenServiceReadds
        seenServiceReadds = machine.serviceReadds
        moveDeparture {
            if droppedByMac { $0.subscriptionsDroppedByMac() }
            $0.linkChanged(
                DepartureLock.Link(phoneLinked: linked, radioOn: radioOn, paired: paired, confirmedNow: reason != nil)
            )
        }
        let subscribed = paired && machine.subscribed
        if subscribed != gattSubscribed {
            gattSubscribed = subscribed
            if subscribed {
                log.info("Bluetooth subscriber present, not yet confirmed as the phone")
            } else {
                log.info("Bluetooth subscriber gone")
            }
        }
        guard linked != phoneLinked else { return }
        phoneLinked = linked
        if linked {
            log.info("phone nearby over Bluetooth, confirmed by \(reason ?? "-", privacy: .public)")
        } else {
            log.info("phone no longer nearby over Bluetooth")
        }
        mirror.submit(.bluetooth(linked: linked))
        session(.bluetooth(linked: linked))
    }

    private static func describe(_ machine: GattPeripheralMachine) -> BridgeStatus.Bluetooth {
        guard machine.enabled else { return .off }
        switch machine.radio {
        case .poweredOn: break
        case .unknown: return .starting
        default: return .unavailable(machine.radio)
        }
        if case .failed(let error) = machine.service { return .failed("service not added: \(error)") }
        if case .failed(let error) = machine.advertising { return .failed("advertising failed: \(error)") }
        return machine.isAdvertising ? .advertising : .starting
    }

    // MARK: Listener

    private func ensureListener() {
        guard listener == nil, let identity = loadIdentity() else { return }
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        startListener(identity: identity, port: (1...65535).contains(saved) ? UInt16(saved) : nil)
    }

    private func startListener(identity: LocalIdentity, port: UInt16?) {
        listenerGeneration += 1
        let generation = listenerGeneration
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        if let local = sec_identity_create(identity.identity) {
            sec_protocol_options_set_local_identity(options, local)
        }
        gate.install(on: options, queue: queue)
        // Spec, Connections: a peer that went away without closing — the phone roamed, or this Mac
        // slept — ends the session within about a minute instead of swallowing what is sent on it.
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        let parameters = NWParameters(tls: tls, tcp: tcp)
        // The Mac often closes first, so a quick restart would find the saved port in TIME_WAIT and
        // move to a new one; the emulator's configured endpoint depends on it staying put.
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
        } catch {
            listenerFailed(requestedPort: port, error: String(describing: error))
            return
        }
        listener.service = service()
        listener.stateUpdateHandler = { state in
            self.assumeIsolated { $0.listenerChanged(state, generation: generation, requestedPort: port) }
        }
        listener.serviceRegistrationUpdateHandler = { change in
            self.assumeIsolated { $0.serviceChanged(change, generation: generation) }
        }
        listener.newConnectionHandler = { connection in
            self.assumeIsolated { $0.accept(connection, generation: generation) }
        }
        self.listener = listener
        status.listener = .starting
        status.bonjour = .registering
        listener.start(queue: queue)
    }

    private func listenerChanged(_ state: NWListener.State, generation: Int, requestedPort: UInt16?) {
        guard generation == listenerGeneration, let listener else { return }
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
            status.listener = .ready(port: port)
            log.info("listener ready on port \(port)")
            openPairingModeIfReady()
        case .failed(let error):
            listenerFailed(requestedPort: requestedPort, error: error.debugDescription)
        case .waiting(let error):
            if case .posix(.EADDRINUSE) = error {
                listenerFailed(requestedPort: requestedPort, error: error.debugDescription)
            } else {
                log.info("listener waiting: \(error.debugDescription, privacy: .public)")
            }
        case .setup, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func listenerFailed(requestedPort: UInt16?, error: String) {
        log.error("listener failed on port \(requestedPort.map(String.init) ?? "any", privacy: .public): \(error, privacy: .public)")
        listener?.cancel()
        listener = nil
        listenerGeneration += 1
        status.bonjour = .off
        if requestedPort != nil, let identity {
            startListener(identity: identity, port: nil)
            return
        }
        status.listener = .failed(error)
        if ceremony?.isActive == true { failCeremony("The bridge could not start listening. \(error)") }
    }

    // Spec, Discovery: `pair=1` joins `v` while pairing mode is on, so the phone finds the Mac that is
    // waiting for it. Setting the service again updates the TXT record in place.
    private func service() -> NWListener.Service {
        status.bonjourPairFlag = ceremony != nil
        return NWListener.Service(
            name: bonjourName(), type: BridgeProtocol.bonjourType,
            txtRecord: NWTXTRecord(BonjourTxt.entries(pairingMode: ceremony != nil))
        )
    }

    private func advertise() {
        guard let listener else { return }
        listener.service = service()
        log.info("bonjour TXT pair flag \(self.ceremony != nil ? "on" : "off", privacy: .public)")
    }

    private func serviceChanged(_ change: NWListener.ServiceRegistrationChange, generation: Int) {
        guard generation == listenerGeneration else { return }
        switch change {
        case .add(let endpoint):
            if case .service(let name, _, _, _) = endpoint {
                status.bonjour = .advertised(name: name)
                log.info("bonjour advertised as \(name, privacy: .public)")
            }
        case .remove:
            status.bonjour = .registering
        @unknown default:
            break
        }
    }

    private func stopListener() {
        guard listener != nil else { return }
        listener?.cancel()
        listener = nil
        listenerGeneration += 1
        status.listener = .stopped
        status.bonjour = .off
        status.bonjourPairFlag = false
        for link in Array(links.values) {
            close(link)
        }
        log.info("listener stopped")
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, generation: Int) {
        guard generation == listenerGeneration else {
            connection.cancel()
            return
        }
        let source = Self.source(of: connection.endpoint)
        let pending = links.values.filter { $0.isPending && $0.transport == .tcp }.map { (id: $0.id, source: $0.source) }
        for id in SessionSlots.evictedByNewTcpConnection(from: source, pending: pending) {
            guard let oldest = links[id] else { continue }
            log.info("connection \(id): closed, too many connections in their handshake")
            close(oldest)
        }
        nextLinkID += 1
        let link = Link(id: nextLinkID, carrier: .tcp(connection), endpoint: "\(connection.endpoint)", source: source)
        links[link.id] = link
        let id = link.id
        connection.stateUpdateHandler = { state in
            self.assumeIsolated { $0.connectionChanged(id, state) }
        }
        armStepTimer(link)
        connection.start(queue: queue)
        log.debug("connection \(id) accepted from \(link.endpoint, privacy: .public)")
    }

    private static func source(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return "\(host)" }
        return "\(endpoint)"
    }

    private func connectionChanged(_ id: Int, _ state: NWConnection.State) {
        guard let link = links[id], case .tcp(let connection) = link.carrier else { return }
        let event: LinkConnectionEvent
        switch state {
        case .ready:
            let fingerprint = TrustGate.peerFingerprint(of: connection)
            if let fingerprint {
                link.peerFingerprint = fingerprint
                log.debug("connection \(id) TLS ready, peer \(String(fingerprint.hex.prefix(8)), privacy: .public)")
            }
            event = .ready(hasPeerCertificate: fingerprint != nil)
        case .failed(let error):
            log.info("connection \(id) failed: \(error.debugDescription, privacy: .public)")
            event = .failed
        case .waiting(let error):
            log.info("connection \(id) waiting: \(error.debugDescription, privacy: .public)")
            event = .waiting
        case .cancelled:
            event = .cancelled
        case .setup, .preparing:
            return
        @unknown default:
            return
        }
        apply(link.machine.connection(event), on: link)
    }

    // Carries out a machine's effects in order; once the link is gone the rest is moot.
    private func apply(_ effects: [LinkEffect], on link: Link) {
        for effect in effects {
            guard links[link.id] != nil else { return }
            switch effect {
            case .send(let message):
                send(message, on: link)
            case .armStepTimer:
                armStepTimer(link)
            case .cancelStepTimer:
                link.stepTimer?.cancel()
            case .startReceiving:
                // The pump delivers on its own from the channel's start.
                if link.transport == .tcp { receive(link) }
            case .establishSession:
                establishSession(link)
            case .beginPairing(let commit):
                beginPairing(commit, on: link)
            case .toCeremony(let message):
                drive { $0.receive(message) }
            case .toSession(let message):
                receivedInSession(message, on: link)
            case .close(.bye) where link.lockAnswersOwed > 0:
                protocolLog.debug("bye on conn=\(link.id) waits for the answer to its lock")
                link.closeWhenAnswered = true
            case .close(let reason):
                logClose(reason, link.id)
                close(link)
            case .detach:
                detach(link)
            }
        }
    }

    private func logClose(_ reason: LinkCloseReason, _ id: Int) {
        switch reason {
        case .noPeerCertificate:
            log.info("connection \(id) has no peer certificate")
        case .notHello(let type):
            log.info("connection \(id): first frame was \(type, privacy: .private), not hello")
        case .versionMismatch(let peer):
            log.info("connection \(id): peer protocol version \(peer), ours \(BridgeProtocol.version)")
        case .unpinnedSession:
            log.info("connection \(id): session from an unpinned peer refused")
        case .notInPairingMode:
            log.info("connection \(id): pair-request outside pairing mode")
        case .busy:
            log.info("connection \(id): pair-request while another pairing runs, answered busy")
        case .protocolError(let type):
            log.info("protocol error: \(type, privacy: .public) on session \(id)")
        case .stepTimeout(.handshaking) where links[id]?.transport == .l2cap:
            log.info("l2cap connection \(id): handshake failed, timed out")
        case .stepTimeout(let stage):
            log.info("connection \(id) timed out waiting in \(String(describing: stage), privacy: .public)")
        case .connectionWaiting, .dataBeforeTls, .bye:
            break
        }
    }

    // One timer per connection, covering the TLS handshake and then each wait for the peer's next
    // step; it dies with the connection.
    private func armStepTimer(_ link: Link) {
        link.stepTimer?.cancel()
        let id = link.id
        let stage = link.stage
        link.stepTimer = Task {
            try? await Task.sleep(for: Self.stepTimeout, tolerance: .seconds(1), clock: .continuous)
            guard !Task.isCancelled else { return }
            self.stepExpired(id, stage)
        }
    }

    private func stepExpired(_ id: Int, _ stage: LinkStage) {
        guard let link = links[id] else { return }
        apply(link.machine.stepExpired(armedIn: stage, ceremonyPresent: ceremony != nil), on: link)
    }

    private func receive(_ link: Link) {
        guard case .tcp(let connection) = link.carrier else { return }
        let id = link.id
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            self.assumeIsolated { $0.received(id, data: data, isComplete: isComplete, failed: error != nil) }
        }
    }

    private func received(_ id: Int, data: Data?, isComplete: Bool, failed: Bool) {
        guard let link = links[id] else { return }
        if let data { link.decoder.append(data) }
        guard handleFrames(on: link) else { return }
        if isComplete || failed {
            peerClosed(link)
            return
        }
        receive(link)
    }

    // The same frames as over TCP, whichever carrier brought the bytes. False once the link is gone.
    private func handleFrames(on link: Link) -> Bool {
        do {
            while let event = try link.decoder.next() {
                handle(event, on: link)
                guard links[link.id] != nil else { return false }
            }
        } catch {
            log.info("connection \(link.id) malformed input: \(String(describing: error), privacy: .private)")
            close(link)
            return false
        }
        return true
    }

    private func peerClosed(_ link: Link) {
        do {
            try link.decoder.finish()
            log.debug("connection \(link.id) closed by the peer")
        } catch {
            log.info("connection \(link.id) malformed input: \(String(describing: error), privacy: .private)")
        }
        close(link)
    }

    // MARK: L2CAP

    // Spec, L2CAP transport: a channel is always a session connection. Until its first record opens it
    // is a pending connection like a TCP one in its TLS handshake, under the same step timer but a cap
    // of its own, and it can touch nothing: a foreign central gets as far as a public key.
    private func l2capOpened(_ pump: L2capStreamPump) {
        guard let pairing else {
            log.info("l2cap channel refused: not paired")
            pump.refuse()
            ble?.channelChanged(pump.peer, open: false)
            return
        }
        let unauthenticated = links.values.filter { $0.transport == .l2cap && !$0.authenticated }.map(\.id)
        for id in SessionSlots.evictedByNewL2capChannel(unauthenticated: unauthenticated) {
            guard let oldest = links[id] else { continue }
            log.info("l2cap connection \(id): closed, too many channels in their handshake")
            close(oldest)
        }
        nextLinkID += 1
        ble?.channelChanged(pump.peer, open: true)
        let endpoint = "l2cap \(pump.peer.uuidString.prefix(8)) psm \(pump.psm)"
        let link = Link(id: nextLinkID, carrier: .l2cap(pump), endpoint: endpoint)
        link.records = MacL2capChannel(kBle: SymmetricKey(data: pairing.kBle))
        links[link.id] = link
        let id = link.id
        let queue = queue
        armStepTimer(link)
        pump.start { event in
            queue.async { self.assumeIsolated { $0.l2capEvent(id, event) } }
        }
        log.info("l2cap connection \(id) opened from \(endpoint, privacy: .public), awaiting the handshake")
    }

    private func l2capEvent(_ id: Int, _ event: L2capPumpEvent) {
        guard let link = links[id], var records = link.records else { return }
        switch event {
        case .bytes(let data):
            let input = records.receive(data)
            link.records = records
            l2capReceived(input, on: link)
        case .ended:
            do {
                try records.finish()
            } catch {
                l2capFailed(error, on: link, beforeAuthentication: !link.authenticated)
                return
            }
            if !link.authenticated { log.info("l2cap connection \(id): handshake failed, the central closed") }
            peerClosed(link)
        case .failed(let reason):
            log.info("l2cap connection \(id) failed: \(reason, privacy: .public)")
            peerClosed(link)
        }
    }

    // A record that opens first stands for the pinned TLS handshake: hello goes out then, and the
    // plaintext it carried is read as the first frames.
    private func l2capReceived(_ input: MacL2capChannel.Input, on link: Link) {
        if let reply = input.reply, case .l2cap(let pump) = link.carrier {
            pump.send(reply)
            armStepTimer(link)
            protocolLog.debug("l2cap connection \(link.id): ephemeral keys exchanged, waiting for the first record")
        }
        if input.authenticated {
            link.authenticated = true
            log.info("l2cap connection \(link.id): handshake ok, first record opened")
            apply(link.machine.connection(.ready(hasPeerCertificate: true)), on: link)
            guard links[link.id] != nil else { return }
        }
        if !input.plaintext.isEmpty {
            link.decoder.append(input.plaintext)
            guard handleFrames(on: link) else { return }
        }
        if input.authenticated || !input.plaintext.isEmpty, case .l2cap(let pump) = link.carrier {
            recordsOpened(from: pump.peer)
        }
        if let failure = input.failure {
            l2capFailed(failure, on: link, beforeAuthentication: !link.authenticated)
        }
    }

    // Fatal either way, and closed without a reply.
    private func l2capFailed(_ rejection: L2capRejection, on link: Link, beforeAuthentication: Bool) {
        if beforeAuthentication {
            log.info("l2cap connection \(link.id): handshake failed, \(String(describing: rejection), privacy: .public)")
        } else {
            log.info("l2cap connection \(link.id): record rejected, \(String(describing: rejection), privacy: .public)")
        }
        close(link)
    }

    private func handle(_ event: TcpFrameEvent, on link: Link) {
        let message: BridgeMessage
        switch event {
        case .unknown(let type):
            let effects = link.machine.receivedUnknown(type: type)
            if effects.isEmpty { protocolLog.debug("recv \(type, privacy: .private) conn=\(link.id) unknown type, ignored") }
            apply(effects, on: link)
            return
        case .message(let known):
            message = known
        }
        logReceived(message, on: link)
        if case .hello(_, let clipboardFromMac) = message { link.clipboardFromMac = clipboardFromMac }
        let context = LinkContext(
            isPinned: isPinned(link), ceremony: ceremonyState, lastPairingModeExpired: lastPairingModeExpired
        )
        apply(link.machine.received(message, context: context), on: link)
    }

    private var ceremonyState: CeremonyState {
        guard let ceremony else { return .none }
        return ceremony.phase == .waiting ? .open : .busy
    }

    // The Mac has sent its hello on every connection past the handshake, so `busy` is readable there.
    private func beginPairing(_ commit: String, on link: Link) {
        slots.bindCeremony(link.id)
        pairingModeTimer?.cancel()
        pairingModeTimer = nil
        // An L2CAP link can never become a pairing one, so pairing mode does not concern it.
        let candidates = links.values.map {
            (id: $0.id, stage: $0.stage, isPinned: $0.transport == .l2cap || isPinned($0))
        }
        for id in SessionSlots.closedByPairRequest(on: link.id, links: candidates) {
            guard let other = links[id] else { continue }
            if other.stage != .handshaking { send(.pairAbort(.busy), on: other) }
            log.info("connection \(id): closed, pairing mode is taken")
            close(other)
        }
        refreshConnectionStatus()
        let fingerprint = link.peerFingerprint
        drive { $0.receivePairRequest(commit: commit, fpPhone: fingerprint) }
    }

    // An L2CAP link is keyed under the current K_ble: a new pairing or an unpairing closes the others.
    private func isPinned(_ link: Link) -> Bool {
        switch link.transport {
        case .tcp: pairing?.peerFingerprint == link.peerFingerprint
        case .l2cap: pairing != nil && link.authenticated
        }
    }

    private func send(_ message: BridgeMessage, on link: Link) {
        let frame: Data
        do {
            frame = try TcpFrame.encode(message)
        } catch {
            log.error("\(message.type, privacy: .public) could not be encoded")
            return
        }
        protocolLog.debug("send \(message.type, privacy: .public) conn=\(link.id)")
        let log = log
        let id = link.id
        switch link.carrier {
        case .tcp(let connection):
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error { log.info("connection \(id) send failed: \(error.debugDescription, privacy: .public)") }
            })
        case .l2cap(let pump):
            do {
                guard var records = link.records else { throw L2capSealError.notKeyed }
                let sealed = try records.seal(frame)
                link.records = records
                pump.send(sealed)
            } catch {
                log.error("connection \(id): \(message.type, privacy: .public) could not be sealed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // Queued frames go out first; the final message closes the write side, then the connection. A
    // peer that stops reading would hold that send forever, so the connection is cancelled after a
    // short grace either way.
    private func close(_ link: Link) {
        detach(link)
        switch link.carrier {
        case .tcp(let connection):
            connection.send(
                content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
            queue.asyncAfter(deadline: .now() + Self.closeGrace) { connection.cancel() }
        case .l2cap(let pump):
            pump.close()
            queue.asyncAfter(deadline: .now() + Self.closeGrace) { pump.cancel() }
        }
    }

    private func detach(_ link: Link) {
        guard links.removeValue(forKey: link.id) != nil else { return }
        link.stepTimer?.cancel()
        if case .l2cap(let pump) = link.carrier { ble?.channelChanged(pump.peer, open: false) }
        let released = slots.detach(link.id)
        if released.contains(.session) {
            coalescer.sessionEnded()
            mirror.submit(.sessionEnded)
            session(.ended)
            // A background visit ends with bye "idle" once it has nothing left to carry: a normal end.
            if let reason = link.byeReason {
                log.info("session \(link.id) ended by the phone's bye \(reason, privacy: .private)")
            } else {
                log.info("session \(link.id) ended")
            }
        }
        if released.contains(.ceremony), ceremony?.isActive == true {
            drive { $0.connectionLost() }
        }
        refreshConnectionStatus()
    }

    private func refreshConnectionStatus() {
        if let id = slots.session, let link = links[id] {
            status.connection = .session(endpoint: link.endpoint, transport: link.transport)
        } else if let id = slots.ceremony, let link = links[id] {
            status.connection = .pairing(endpoint: link.endpoint)
        } else {
            status.connection = .none
        }
    }

    private func logReceived(_ message: BridgeMessage, on link: Link) {
        switch message {
        case .notifDetail(let info):
            protocolLog.debug(
                "recv notif-detail conn=\(link.id) k=\(Signal.keyHash(of: info.key), privacy: .public) title=\(info.title, privacy: .private)"
            )
        case .activeSet(let notifications):
            protocolLog.debug("recv active-set conn=\(link.id) count=\(notifications.count)")
        case .iconData(let hash, let png):
            protocolLog.debug("recv icon-data conn=\(link.id) hash=\(String(hash.prefix(16)), privacy: .public) bytes=\(png.count)")
        case .replyText(let key, _):
            protocolLog.debug("recv reply-text conn=\(link.id) k=\(Signal.keyHash(of: key), privacy: .public)")
        case .clipboardSet(let text, let sensitive, let announce, _):
            protocolLog.debug(
                "recv clipboard-set conn=\(link.id) bytes=\(text.utf8.count) sensitive=\(sensitive) announce=\(announce)"
            )
        case .bye(let reason):
            link.byeReason = reason
            protocolLog.debug("recv bye conn=\(link.id) reason=\(reason ?? "-", privacy: .private)")
        default:
            protocolLog.debug("recv \(message.type, privacy: .public) conn=\(link.id)")
        }
    }

    // MARK: Identity

    private func loadIdentity() -> LocalIdentity? {
        if let identity { return identity }
        do {
            let loaded = try store.loadOrCreateIdentity()
            identity = loaded
            status.storageError = nil
            log.info("identity fingerprint \(String(loaded.fingerprint.hex.prefix(8)), privacy: .public)")
            return loaded
        } catch {
            report(error, "Loading the bridge identity")
            return nil
        }
    }

    private func bonjourName() -> String {
        if let instanceName { return instanceName }
        let name = NetworkInfo.instanceName
        instanceName = name
        return name
    }

    private func report(_ error: any Error, _ context: String) {
        log.error("\(context, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        status.storageError = "\(context) failed: \(error)"
    }
}

nonisolated private final class Link {
    enum Carrier {
        case tcp(NWConnection)
        case l2cap(L2capStreamPump)
    }

    let id: Int
    let carrier: Carrier
    let endpoint: String
    let source: String
    var machine: LinkMachine
    var decoder = TcpFrameDecoder()
    var records: MacL2capChannel?
    var authenticated = false
    var peerFingerprint = Data()
    var stepTimer: Task<Void, Never>?
    var iconRequests = IconRequests()
    var stateSynced = false
    var byeReason: String?
    var clipboardFromMac: Bool?
    var lockAnswersOwed = 0
    var closeWhenAnswered = false

    var stage: LinkStage { machine.stage }
    var isPending: Bool { machine.stage.isPending }
    var transport: LinkTransport { machine.transport }

    init(id: Int, carrier: Carrier, endpoint: String, source: String = "") {
        self.id = id
        self.carrier = carrier
        self.endpoint = endpoint
        self.source = source
        switch carrier {
        case .tcp: machine = LinkMachine(transport: .tcp)
        case .l2cap: machine = LinkMachine(transport: .l2cap)
        }
    }
}
