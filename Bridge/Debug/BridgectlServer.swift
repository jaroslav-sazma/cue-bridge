#if DEBUG
import Foundation
import os

// Serves bridgectl on a unix socket; everything here runs on `queue`.
nonisolated final class BridgectlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.cue.bridge.bridgectl")
    private let status: @Sendable () async -> BridgeStatus
    private let mirror: @Sendable () async -> [MirrorEntry]
    private let reconciler: @Sendable () async -> ReconcilerMachine
    private let clipboard: @Sendable () async -> ClipboardSnapshot
    private let log = Logger(subsystem: "app.cue.bridge", category: "bridgectl")
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    private struct Client {
        let source: DispatchSourceRead
        var buffer = Data()
        var answering = false
    }

    init(
        status: @escaping @Sendable () async -> BridgeStatus,
        mirror: @escaping @Sendable () async -> [MirrorEntry],
        reconciler: @escaping @Sendable () async -> ReconcilerMachine,
        clipboard: @escaping @Sendable () async -> ClipboardSnapshot
    ) {
        self.status = status
        self.mirror = mirror
        self.reconciler = reconciler
        self.clipboard = clipboard
    }

    func start() {
        queue.async { self.open() }
    }

    private func open() {
        let url = BridgectlWire.socketURL
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("bridgectl directory: \(error.localizedDescription, privacy: .public)")
            return
        }
        chmod(directory.path, 0o700)
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return fail("socket", fd: -1) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return fail("path too long", fd: fd) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            path.withUnsafeBytes { buffer.copyMemory(from: $0) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { return fail("bind", fd: fd) }
        chmod(url.path, 0o600)
        guard listen(fd, 4) == 0 else { return fail("listen", fd: fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in acceptClient(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        acceptSource = source
        log.info("bridgectl socket ready at \(url.path, privacy: .public)")
    }

    private func fail(_ step: String, fd: Int32) {
        log.error("bridgectl \(step, privacy: .public) failed: errno \(errno)")
        if fd >= 0 { Darwin.close(fd) }
    }

    private func acceptClient(_ listener: Int32) {
        let fd = accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in readClient(fd) }
        source.setCancelHandler { Darwin.close(fd) }
        clients[fd] = Client(source: source)
        source.resume()
    }

    private func readClient(_ fd: Int32) {
        guard var client = clients[fd], !client.answering else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { return drop(fd) }
        client.buffer.append(contentsOf: chunk[..<count])
        guard let newline = client.buffer.firstIndex(of: 0x0a) else {
            clients[fd] = client
            if client.buffer.count > 65_536 { drop(fd) }
            return
        }
        let line = client.buffer[..<newline]
        // Suspended while the answer is prepared; drop() resumes it before cancelling.
        client.answering = true
        client.source.suspend()
        clients[fd] = client
        let request = try? BridgectlWire.decoder.decode(BridgectlWire.Request.self, from: Data(line))
        switch request?.command {
        case "status":
            Task {
                let response = BridgectlWire.Response(status: Self.wire(await status(), await reconciler()))
                queue.async { self.respond(fd, response) }
            }
        case "mirror-table":
            Task {
                let response = BridgectlWire.Response(mirror: await mirror().map(Self.row))
                queue.async { self.respond(fd, response) }
            }
        case "clipboard":
            Task {
                let response = BridgectlWire.Response(clipboard: Self.wire(await clipboard()))
                queue.async { self.respond(fd, response) }
            }
        default:
            respond(fd, BridgectlWire.Response(error: "unknown command"))
        }
    }

    private static func row(_ entry: MirrorEntry) -> BridgectlWire.MirrorRow {
        BridgectlWire.MirrorRow(
            keyHash: entry.keyHash, pkg: entry.info.pkg,
            threadIdentifier: MirrorRendering.threadIdentifier(entry.info), hasIcon: entry.hasIcon,
            pending: entry.pending, title: MirrorRendering.title(entry.info), body: entry.info.text
        )
    }

    private static func wire(_ snapshot: ClipboardSnapshot) -> BridgectlWire.Clipboard {
        func row(_ record: ClipRecord?) -> BridgectlWire.ClipRow? {
            record.map {
                BridgectlWire.ClipRow(
                    direction: $0.direction.rawValue, type: $0.wireType, bytes: $0.bytes, sensitive: $0.sensitive,
                    announce: $0.announce, at: $0.at
                )
            }
        }
        return BridgectlWire.Clipboard(
            publisher: snapshot.machine.armed ? "armed" : "idle", idle: snapshot.machine.idle?.rawValue,
            intervalSeconds: ClipboardPublisherMachine.intervalSeconds, accessBehavior: snapshot.accessBehavior,
            changeCount: snapshot.changeCount, lastSent: row(snapshot.lastSent), lastReceived: row(snapshot.lastReceived),
            lastSkipped: snapshot.lastSkip?.rawValue, lastSkippedAt: snapshot.lastSkipAt, tombstones: snapshot.tombstones
        )
    }

    private func respond(_ fd: Int32, _ response: BridgectlWire.Response) {
        if var data = try? BridgectlWire.encoder.encode(response) {
            data.append(0x0a)
            data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    guard written > 0 else { break }
                    offset += written
                }
            }
        }
        drop(fd)
    }

    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        if client.answering { client.source.resume() }
        client.source.cancel()
    }

    private static func wire(_ status: BridgeStatus, _ reconciler: ReconcilerMachine) -> BridgectlWire.Status {
        var wire = BridgectlWire.Status(
            protocolVersion: BridgeProtocol.version,
            paired: status.peerFingerprint != nil,
            pairingUnusable: status.pairingUnusable != nil,
            pairingUnusableReason: status.pairingUnusable?.rawValue,
            peerFingerprintPrefix: status.peerFingerprintPrefix,
            pairingMode: "off",
            listener: "stopped",
            bonjour: "off",
            connection: "none",
            lastStateSyncCount: status.lastStateSync?.count,
            lastStateSyncAt: status.lastStateSync?.at,
            lastStateSyncAdded: status.lastStateSync?.added,
            lastStateSyncUpdated: status.lastStateSync?.updated,
            lastStateSyncRemoved: status.lastStateSync?.removed,
            lastStateSyncUntouched: status.lastStateSync?.untouched,
            mirroredCount: status.mirroredCount,
            storageError: status.storageError,
            reconcilerMode: reconciler.periodic ? "periodic" : "event-only",
            reconcilerIntervalSeconds: reconciler.intervalSeconds,
            reconcilerArmed: reconciler.armedSeconds != nil,
            reconcilerIdle: reconciler.idle?.rawValue,
            bluetoothPayload: status.bluetoothPayload,
            bluetoothConfirmed: status.bluetoothConfirmed,
            lastGattSentType: status.lastGattSent?.type,
            lastGattSentAt: status.lastGattSent?.at,
            lastGattReceivedType: status.lastGattReceived?.type,
            lastGattReceivedAt: status.lastGattReceived?.at
        )
        switch status.bluetooth {
        case .off: wire.bluetooth = "off"
        case .starting: wire.bluetooth = "starting"
        case .advertising: wire.bluetooth = "advertising"
        case .unavailable(let radio): wire.bluetooth = radio.rawValue
        case .failed(let error): wire.bluetooth = "failed: \(error)"
        }
        switch status.l2cap {
        case .idle: wire.l2cap = "not published"
        case .publishing: wire.l2cap = "publishing"
        case .published(let psm):
            wire.l2cap = "published"
            wire.l2capPsm = Int(psm)
        case .failed(let error): wire.l2cap = "failed: \(error)"
        }
        switch status.pairing {
        case .idle, .committed, .aborted, .failed: wire.pairingMode = "off"
        case .preparing: wire.pairingMode = "preparing"
        case .waiting: wire.pairingMode = "waiting for a phone"
        case .verifying: wire.pairingMode = "waiting for the phone's key"
        case .enteringCode(let rejected): wire.pairingMode = "entering the code (\(rejected) wrong so far)"
        case .codeAccepted: wire.pairingMode = "code accepted, waiting for the phone's proof"
        }
        switch status.listener {
        case .stopped: wire.listener = "stopped"
        case .starting: wire.listener = "starting"
        case .ready(let port):
            wire.listener = "ready"
            wire.listenerPort = Int(port)
        case .failed(let error): wire.listener = "failed: \(error)"
        }
        switch status.bonjour {
        case .off: wire.bonjour = "off"
        case .registering: wire.bonjour = "registering"
        case .advertised(let name):
            wire.bonjour = "advertised"
            wire.bonjourName = name
            wire.bonjourPairFlag = status.bonjourPairFlag
        }
        switch status.connection {
        case .none: wire.connection = "none"
        case .pairing(let endpoint):
            wire.connection = "pairing"
            wire.peerEndpoint = endpoint
        case .session(let endpoint, let transport):
            wire.connection = "session"
            wire.sessionTransport = transport.rawValue
            wire.peerEndpoint = endpoint
        }
        return wire
    }
}
#endif
