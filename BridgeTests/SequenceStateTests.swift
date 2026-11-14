import Foundation
import Testing

private let kBle = Data(repeating: 7, count: 32)
private let otherKey = Data(repeating: 8, count: 32)

private func temporaryFile() -> SequenceFile {
    SequenceFile(
        url: FileManager.default.temporaryDirectory
            .appending(path: "sequence-tests-\(UUID().uuidString)/Sequence", directoryHint: .isDirectory)
            .appending(path: "state")
    )
}

// What a restart finds is what was persisted; everything else in the book is lost with the process.
private struct Disk {
    var state: SequenceState

    mutating func take(_ book: inout SequenceBook) -> UInt32? {
        if case .reserve(let reservation) = book.nextOutgoing() {
            state = reservation
            book.reserved(reservation)
        }
        guard case .seq(let seq) = book.nextOutgoing() else { return nil }
        #expect(UInt64(seq) < state.outgoingBound, "a seq leaves only below the persisted bound")
        book.spend(seq)
        return seq
    }
}

@Suite("sequence state")
struct SequenceStateTests {
    @Test("a block of 64 is reserved before its first seq and costs one save")
    func blockReservation() {
        var book = SequenceBook(SequenceState(fresh: kBle))
        var firstBlock = SequenceState(fresh: kBle)
        firstBlock.outgoingBound = 64
        #expect(book.nextOutgoing() == .reserve(firstBlock))
        var disk = Disk(state: SequenceState(fresh: kBle))
        var saves = 0
        var handedOut: [UInt32] = []
        for _ in 0 ..< 65 {
            if case .reserve = book.nextOutgoing() { saves += 1 }
            handedOut.append(disk.take(&book) ?? .max)
        }
        #expect(handedOut == Array(0 ... 64))
        #expect(saves == 2 && disk.state.outgoingBound == 128)
    }

    @Test("a restart continues above the persisted bound: a gap, never a seq used twice")
    func restart() {
        var disk = Disk(state: SequenceState(fresh: kBle))
        var book = SequenceBook(disk.state)
        let before = (0 ..< 3).compactMap { _ in disk.take(&book) }
        var restarted = SequenceBook(disk.state)
        let after = (0 ..< 2).compactMap { _ in disk.take(&restarted) }
        #expect(before == [0, 1, 2] && after == [64, 65])
        #expect(disk.state.outgoingBound == 128)
    }

    @Test("a block whose save failed is not handed out")
    func failedReservation() {
        let book = SequenceBook(SequenceState(fresh: kBle))
        guard case .reserve = book.nextOutgoing() else {
            Issue.record("a fresh book has nothing reserved")
            return
        }
        #expect(book.nextOutgoing() != .seq(0), "without reserved(_:) nothing may leave")
    }

    @Test("no seq past the last usable one")
    func exhaustion() {
        var state = SequenceState(fresh: kBle)
        state.outgoingBound = SequenceState.exhausted - 2
        var disk = Disk(state: state)
        var book = SequenceBook(state)
        #expect(disk.take(&book) == SignalFrame.lastSeq - 1)
        #expect(disk.take(&book) == SignalFrame.lastSeq)
        #expect(disk.take(&book) == nil && book.nextOutgoing() == .exhausted)
        #expect(disk.state.outgoingBound == SequenceState.exhausted)
    }

    @Test("an accepted frame's window is what gets persisted")
    func incoming() throws {
        var book = SequenceBook(SequenceState(fresh: kBle))
        var window = book.window
        window.record(5)
        window.record(3)
        var persisted: SequenceState?
        try book.accept(window) { persisted = $0 }
        #expect(persisted?.incoming == window && book.window == window)
        #expect(persisted?.incoming.permits(3) == false && persisted?.incoming.permits(4) == true)
    }

    @Test("a frame whose window could not be saved leaves the window where it was")
    func failedAcceptance() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent().deletingLastPathComponent()) }
        var book = SequenceBook(SequenceState(fresh: kBle))
        var first = book.window
        first.record(0)
        try book.accept(first) { try file.save($0, durable: false) }

        var second = book.window
        second.record(1)
        #expect(throws: POSIXError.self) {
            try book.accept(second) { _ in throw POSIXError(.ENOSPC) }
        }
        #expect(book.window == first, "the frame is dropped, so it was never seen")
        #expect(book.window.permits(1))
        #expect(try file.load().incoming == first, "a restart finds the same window the book holds")
        #expect(SequenceBook(try file.load()) == book)
    }

    @Test("the encoding round-trips and rejects anything malformed")
    func encoding() throws {
        var state = SequenceState(fresh: kBle)
        state.outgoingBound = 4_096
        state.incoming = .accepting([70, 3, 69])
        let encoded = state.encoded
        #expect(SequenceState(encoded: encoded) == state)
        #expect(SequenceState(encoded: SequenceState(fresh: kBle).encoded) == SequenceState(fresh: kBle))

        #expect(SequenceState(encoded: encoded.dropLast()) == nil)
        #expect(SequenceState(encoded: Data()) == nil)
        for offset in [0, 10, 25, 30, 40, encoded.count - 1] {
            var flipped = encoded
            flipped[offset] ^= 0x01
            #expect(SequenceState(encoded: flipped) == nil, "a flipped bit at \(offset)")
        }
    }

    @Test("a window that holds no seq of its own highest is not a window")
    func windowValidation() {
        #expect(ReplayWindow(highest: nil, seen: 0) == ReplayWindow())
        #expect(ReplayWindow(highest: nil, seen: 1) == nil)
        #expect(ReplayWindow(highest: 5, seen: 2) == nil)
        #expect(ReplayWindow(highest: 5, seen: 3) == ReplayWindow.accepting([4, 5]))
    }

    @Test("the state belongs to one key")
    func keyTag() {
        #expect(SequenceState(fresh: kBle).belongs(to: kBle))
        #expect(!SequenceState(fresh: kBle).belongs(to: otherKey))
        #expect(SequenceState.keyTag(for: kBle).count == 16)
        #expect(SequenceState.keyTag(for: kBle) != kBle.prefix(16))
    }
}

@Suite("sequence file")
struct SequenceFileTests {
    @Test("saved state loads again, owner-only and kept out of backups")
    func roundTrip() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent().deletingLastPathComponent()) }
        var state = SequenceState(fresh: kBle)
        state.outgoingBound = 64
        try file.save(state, durable: true)
        state.incoming = .accepting([0])
        try file.save(state, durable: false)

        #expect(try file.load() == state)
        #expect(file.load(for: kBle) == .usable(SequenceBook(state)))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directory = file.url.deletingLastPathComponent()
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers == ["state"], "no temporary file stays behind")
    }

    // The fail-closed path: a pairing key with no usable state of its own is never given a fresh counter.
    @Test("a key whose state is missing, malformed, unreadable or another key's is unusable")
    func failClosed() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(file.load(for: kBle) == .unusable(reason: "missing"))

        try file.save(SequenceState(fresh: otherKey), durable: true)
        #expect(file.load(for: kBle) == .unusable(reason: "belongs to another key"))

        var corrupted = try Data(contentsOf: file.url)
        corrupted[22] ^= 0xff
        try corrupted.write(to: file.url)
        #expect(file.load(for: otherKey) == .unusable(reason: "malformed"))

        try Data("garbage".utf8).write(to: file.url)
        #expect(file.load(for: kBle) == .unusable(reason: "malformed"))

        try file.delete()
        try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: false)
        guard case .unusable(let reason) = file.load(for: kBle) else {
            Issue.record("a state that cannot be read is unusable")
            return
        }
        #expect(reason.hasPrefix("unreadable"))
    }

    @Test("a save that cannot be completed throws and leaves the state on disk as it was")
    func failedSave() throws {
        let file = temporaryFile()
        let directory = file.url.deletingLastPathComponent()
        defer {
            chmod(directory.path, 0o700)
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        var state = SequenceState(fresh: kBle)
        state.outgoingBound = 64
        try file.save(state, durable: true)
        chmod(directory.path, 0o500)
        var later = state
        later.outgoingBound = 128
        #expect(throws: POSIXError.self) { try file.save(later, durable: true) }
        #expect(try file.load() == state)
    }

    @Test("unpairing deletes the file, and deleting nothing is fine")
    func delete() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent().deletingLastPathComponent()) }
        try file.delete()
        try file.save(SequenceState(fresh: kBle), durable: true)
        try file.delete()
        #expect(throws: SequenceFile.Failure.missing) { try file.load() }
    }
}
