import CryptoKit
import Darwin
import Foundation

// Spec, replay window: bit i of `seen` stands for `highest - i`.
nonisolated struct ReplayWindow: Equatable, Sendable {
    static let size: UInt32 = 64

    private(set) var highest: UInt32?
    private(set) var seen: UInt64 = 0

    init() {}

    init?(highest: UInt32?, seen: UInt64) {
        guard highest == nil ? seen == 0 : seen & 1 == 1 else { return nil }
        self.highest = highest
        self.seen = seen
    }

    func permits(_ seq: UInt32) -> Bool {
        guard let highest, seq <= highest else { return true }
        let behind = highest - seq
        return behind < Self.size && seen & (1 << UInt64(behind)) == 0
    }

    mutating func record(_ seq: UInt32) {
        if let highest, seq <= highest {
            seen |= 1 << UInt64(highest - seq)
            return
        }
        let ahead = highest.map { UInt64(seq - $0) } ?? UInt64(Self.size)
        seen = ahead >= UInt64(Self.size) ? 1 : seen << ahead | 1
        highest = seq
    }
}

// The key tag ties the state to one K_ble, which lives elsewhere (the Keychain): a pairing saved
// half-way, a restored Keychain or a stray file leaves state that matches no key, so the pairing is
// unusable instead of counting from zero again next to a kept key.
nonisolated struct SequenceState: Equatable, Sendable {
    static let reservationBlock: UInt64 = 64
    static let exhausted = UInt64(SignalFrame.lastSeq) + 1

    private static let magic = Data("CSQ1".utf8)
    private static let bodyBytes = 4 + 16 + 8 + 1 + 4 + 8
    private static let checksumBytes = 8

    var keyTag: Data
    var outgoingBound: UInt64 = 0
    var incoming = ReplayWindow()

    static func keyTag(for kBle: Data) -> Data {
        Data(SHA256.hash(data: Data("cue-bridge/sequence-state".utf8) + kBle).prefix(16))
    }

    init(fresh kBle: Data) {
        keyTag = Self.keyTag(for: kBle)
    }

    func belongs(to kBle: Data) -> Bool {
        keyTag == Self.keyTag(for: kBle)
    }

    var encoded: Data {
        var body = Self.magic
        body.append(keyTag)
        body.appendUInt64(outgoingBound)
        body.append(incoming.highest == nil ? 0 : 1)
        body.appendUInt32(incoming.highest ?? 0)
        body.appendUInt64(incoming.seen)
        return body + Self.checksum(body)
    }

    init?(encoded data: Data) {
        let data = Data(data)
        guard data.count == Self.bodyBytes + Self.checksumBytes else { return nil }
        let body = data.prefix(Self.bodyBytes)
        guard body.prefix(4) == Self.magic, data.suffix(Self.checksumBytes) == Self.checksum(body) else { return nil }
        let bound = UInt64(data.uint32(at: 20)) << 32 | UInt64(data.uint32(at: 24))
        let flag = data[28]
        let highest = data.uint32(at: 29)
        let seen = UInt64(data.uint32(at: 33)) << 32 | UInt64(data.uint32(at: 37))
        guard bound <= Self.exhausted, flag <= 1, flag == 1 || highest == 0,
              let window = ReplayWindow(highest: flag == 1 ? highest : nil, seen: seen)
        else { return nil }
        keyTag = data.subdata(in: 4 ..< 20)
        outgoingBound = bound
        incoming = window
    }

    private static func checksum(_ body: Data) -> Data {
        Data(SHA256.hash(data: body).prefix(checksumBytes))
    }
}

// Outgoing numbers come out of a block whose bound is on disk first: a crash costs a gap and never a
// nonce used twice under one K_ble. Two steps, so a block whose save failed is never handed out.
nonisolated struct SequenceBook: Equatable, Sendable {
    enum Outgoing: Equatable, Sendable {
        case seq(UInt32)
        // Persist this state, hand it to `reserved(_:)`, then ask again.
        case reserve(SequenceState)
        case exhausted
    }

    private(set) var stored: SequenceState
    private var next: UInt64

    init(_ stored: SequenceState) {
        self.stored = stored
        next = stored.outgoingBound
    }

    var window: ReplayWindow { stored.incoming }

    func nextOutgoing() -> Outgoing {
        if next < stored.outgoingBound { return .seq(UInt32(next)) }
        guard next < SequenceState.exhausted else { return .exhausted }
        var reservation = stored
        reservation.outgoingBound = min(next + SequenceState.reservationBlock, SequenceState.exhausted)
        return .reserve(reservation)
    }

    mutating func reserved(_ state: SequenceState) {
        stored = state
    }

    mutating func spend(_ seq: UInt32) {
        next = UInt64(seq) + 1
    }

    // Returns the state to persist.
    mutating func accepted(_ window: ReplayWindow) -> SequenceState {
        stored.incoming = window
        return stored
    }
}

nonisolated enum SequenceLoad: Equatable, Sendable {
    case usable(SequenceBook)
    case unusable(reason: String)
}

nonisolated struct SequenceFile: Sendable {
    enum Failure: Error, Equatable {
        case missing
        case malformed
    }

    let url: URL

    // Its own directory, kept out of Time Machine: a restored Keychain then finds no state and the
    // pairing is unusable, where a restored file would roll the counters back under the same key.
    static var standard: SequenceFile {
        SequenceFile(
            url: URL.applicationSupportDirectory.appending(path: "Cue Bridge/Sequence", directoryHint: .isDirectory)
                .appending(path: "state")
        )
    }

    func load() throws -> SequenceState {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw Failure.missing
        }
        guard let state = SequenceState(encoded: data) else { throw Failure.malformed }
        return state
    }

    // Never falls back: whatever goes wrong, the pairing is unusable until it is made again.
    func load(for kBle: Data) -> SequenceLoad {
        do {
            let state = try load()
            return state.belongs(to: kBle) ? .usable(SequenceBook(state)) : .unusable(reason: "belongs to another key")
        } catch Failure.missing {
            return .unusable(reason: "missing")
        } catch Failure.malformed {
            return .unusable(reason: "malformed")
        } catch {
            return .unusable(reason: "unreadable: \(error.localizedDescription)")
        }
    }

    // A reservation waits for the drive (F_FULLFSYNC), so a power cut cannot roll a bound back; the
    // window after an accepted frame only for the file's own data.
    func save(_ state: SequenceState, durable: Bool) throws {
        let directory = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var directoryURL = directory
            try directoryURL.setResourceValues(excluded)
        }
        let temporary = directory.appending(path: ".state-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var failure: POSIXErrorCode?
        let bytes = state.encoded
        let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if written != bytes.count || !Self.flush(fd, durable: durable) {
            failure = POSIXErrorCode(rawValue: errno) ?? .EIO
        }
        close(fd)
        if failure == nil, rename(temporary.path, url.path) != 0 {
            failure = POSIXErrorCode(rawValue: errno) ?? .EIO
        }
        if let failure {
            unlink(temporary.path)
            throw POSIXError(failure)
        }
    }

    // F_FULLFSYNC fails on file systems that cannot honour it; fsync is the most those can give.
    private static func flush(_ fd: Int32, durable: Bool) -> Bool {
        if durable, fcntl(fd, F_FULLFSYNC) == 0 { return true }
        return fsync(fd) == 0
    }

    func delete() throws {
        guard unlink(url.path) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
