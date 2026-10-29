import Foundation

let usage = """
    usage: bridgectl status [--json]
           bridgectl mirror-table [--json]
           bridgectl clipboard [--json]

    Talks to a running Debug build of Cue Bridge over its debug socket.
    """

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func request(_ command: String) -> Data {
    let path = BridgectlWire.socketURL.path
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("bridgectl: cannot create a socket (errno \(errno))", code: 3) }
    defer { close(fd) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { fail("bridgectl: socket path too long", code: 3) }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        bytes.withUnsafeBytes { buffer.copyMemory(from: $0) }
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
        fail("bridgectl: Cue Bridge is not running, or is not a Debug build (no answer at \(path))", code: 1)
    }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    var line = (try? JSONEncoder().encode(BridgectlWire.Request(command: command))) ?? Data()
    line.append(0x0a)
    let sent = line.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
    guard sent == line.count else { fail("bridgectl: the request could not be sent (errno \(errno))", code: 3) }
    var response = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while !response.contains(0x0a) {
        let count = read(fd, &chunk, chunk.count)
        guard count > 0 else { break }
        response.append(contentsOf: chunk[..<count])
    }
    guard let end = response.firstIndex(of: 0x0a) else { fail("bridgectl: no answer from Cue Bridge", code: 3) }
    return response[..<end]
}

func traffic(_ type: String?, _ at: Date?) -> String {
    guard let type, let at else { return "none" }
    return "\(type), \(max(0, Int(Date.now.timeIntervalSince(at).rounded()))) s ago"
}

func describe(_ status: BridgectlWire.Status) -> String {
    var lines = ["protocol version: \(status.protocolVersion)"]
    let paired = status.paired
        ? "yes, peer \(status.peerFingerprintPrefix ?? "?")"
        : status.pairingUnusable == true ? "unusable, \(status.pairingUnusableReason ?? "?"); pair again" : "no"
    lines.append("paired: " + paired)
    lines.append("pairing mode: \(status.pairingMode)")
    lines.append("listener: \(status.listener)" + (status.listenerPort.map { " on port \($0)" } ?? ""))
    lines.append(
        "bonjour: \(status.bonjour)" + (status.bonjourName.map { " as \"\($0)\"" } ?? "")
            + (status.bonjourPairFlag.map { $0 ? ", TXT v=1 pair=1" : ", TXT v=1" } ?? "")
    )
    lines.append(
        "connection: \(status.connection)" + (status.sessionTransport.map { " over \($0)" } ?? "")
            + (status.peerEndpoint.map { " from \($0)" } ?? "")
    )
    if let bluetooth = status.bluetooth {
        lines.append("bluetooth: \(bluetooth)")
        let subscription = status.bluetoothPayload.map { payload in
            status.bluetoothConfirmed == true
                ? "confirmed, payload \(payload) bytes"
                : "subscribed, not confirmed, payload \(payload) bytes"
        }
        lines.append("phone over bluetooth: " + (subscription ?? "not subscribed"))
        if let l2cap = status.l2cap {
            lines.append("l2cap: \(l2cap)" + (status.l2capPsm.map { ", psm \($0)" } ?? ""))
        }
        lines.append("last gatt signal sent: \(traffic(status.lastGattSentType, status.lastGattSentAt))")
        lines.append("last gatt signal received: \(traffic(status.lastGattReceivedType, status.lastGattReceivedAt))")
    }
    if let count = status.lastStateSyncCount, let at = status.lastStateSyncAt {
        var line = "last state-sync: \(count) notifications at \(at.formatted(.iso8601))"
        if let added = status.lastStateSyncAdded, let updated = status.lastStateSyncUpdated,
           let removed = status.lastStateSyncRemoved, let untouched = status.lastStateSyncUntouched {
            line += " (added \(added), updated \(updated), removed \(removed), untouched \(untouched))"
        }
        lines.append(line)
    } else {
        lines.append("last state-sync: none")
    }
    lines.append("mirrored: \(status.mirroredCount)")
    if let mode = status.reconcilerMode, let interval = status.reconcilerIntervalSeconds, let armed = status.reconcilerArmed {
        let state = armed ? "armed" : "disarmed" + (status.reconcilerIdle.map { " (\($0))" } ?? "")
        lines.append("reconciler: \(mode), interval \(interval) s, \(state)")
    }
    if let error = status.storageError {
        lines.append("storage error: \(error)")
    }
    return lines.joined(separator: "\n")
}

func describe(_ rows: [BridgectlWire.MirrorRow]) -> String {
    guard !rows.isEmpty else { return "no mirrored notifications" }
    return rows.map { row in
        [
            row.keyHash, row.pkg, "thread=\(row.threadIdentifier)",
            "icon=\(row.pending ? "pending" : row.hasIcon ? "yes" : "no")",
            "title=\(String(reflecting: row.title))", "body=\(String(reflecting: row.body))",
        ].joined(separator: "  ")
    }.joined(separator: "\n")
}

func describe(_ clipboard: BridgectlWire.Clipboard) -> String {
    func age(_ date: Date) -> String {
        "\(max(0, Int(Date.now.timeIntervalSince(date).rounded()))) s ago"
    }
    func describe(_ row: BridgectlWire.ClipRow?) -> String {
        guard let row else { return "none" }
        return "\(row.direction) \(row.type), \(row.bytes) bytes, sensitive=\(row.sensitive), announce=\(row.announce), \(age(row.at))"
    }
    let publisher = clipboard.publisher == "armed"
        ? "armed, every \(clipboard.intervalSeconds) s"
        : "idle" + (clipboard.idle.map { " (\($0))" } ?? "")
    var lines = ["publisher: \(publisher)"]
    lines.append("pasteboard access: \(clipboard.accessBehavior)")
    lines.append("last changeCount seen: \(clipboard.changeCount.map(String.init) ?? "none")")
    lines.append("last sent: \(describe(clipboard.lastSent))")
    lines.append("last received: \(describe(clipboard.lastReceived))")
    if let skipped = clipboard.lastSkipped, let at = clipboard.lastSkippedAt {
        lines.append("last skipped: \(skipped), \(age(at))")
    } else {
        lines.append("last skipped: none")
    }
    lines.append("tombstones: \(clipboard.tombstones)")
    return lines.joined(separator: "\n")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["status", "mirror-table", "clipboard"].contains(command),
      arguments.dropFirst().allSatisfy({ $0 == "--json" })
else {
    fail(usage, code: 2)
}
let raw = request(command)
guard let response = try? BridgectlWire.decoder.decode(BridgectlWire.Response.self, from: raw) else {
    fail("bridgectl: unreadable answer from Cue Bridge", code: 3)
}
let text: String
if command == "status" {
    guard let status = response.status else {
        fail("bridgectl: \(response.error ?? "no status in the answer")", code: 3)
    }
    text = describe(status)
} else if command == "clipboard" {
    guard let clipboard = response.clipboard else {
        fail("bridgectl: \(response.error ?? "no clipboard state in the answer")", code: 3)
    }
    text = describe(clipboard)
} else {
    guard let rows = response.mirror else {
        fail("bridgectl: \(response.error ?? "no mirror table in the answer")", code: 3)
    }
    text = describe(rows)
}
print(arguments.contains("--json") ? String(decoding: raw, as: UTF8.self) : text)
