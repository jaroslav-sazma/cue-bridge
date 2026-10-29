import Foundation
import Synchronization
import Testing

private let thisMac = "11111111-2222-3333-4444-555555555555"
private let otherMac = "66666666-7777-8888-9999-AAAAAAAAAAAA"
private let record = PairingRecord(peerFingerprint: Data(repeating: 1, count: 32), kBle: Data(repeating: 2, count: 32))

// The keychain's semantics without the keychain, which the tests never touch.
nonisolated private final class MemoryItems: SecretItems {
    private let state = Mutex<(items: [String: Data], reads: [String])>(([:], []))

    var accounts: Set<String> { state.withLock { Set($0.items.keys) } }
    var reads: [String] { state.withLock { $0.reads } }

    func read(_ account: String) throws -> Data? {
        state.withLock {
            $0.reads.append(account)
            return $0.items[account]
        }
    }

    func write(_ data: Data, to account: String) throws {
        state.withLock { $0.items[account] = data }
    }

    func delete(_ account: String) throws {
        state.withLock { _ = $0.items.removeValue(forKey: account) }
    }
}

private func temporaryFile() -> SequenceFile {
    SequenceFile(
        url: FileManager.default.temporaryDirectory
            .appending(path: "vault-tests-\(UUID().uuidString)/Sequence", directoryHint: .isDirectory)
            .appending(path: "state")
    )
}

@Suite("Pairing vault")
struct PairingVaultTests {
    @Test("a pairing loads on the Mac it was made on")
    func sameMac() throws {
        let items = MemoryItems()
        let vault = PairingVault(items: items)
        try vault.save(record, on: thisMac)
        #expect(try vault.load(on: thisMac) == .found(record))
    }

    @Test("a pairing made on another Mac is unusable for its own reason, and its key is never read")
    func otherMacFailsClosed() throws {
        let items = MemoryItems()
        let vault = PairingVault(items: items)
        try vault.save(record, on: otherMac)
        let file = temporaryFile()
        try file.save(SequenceState(fresh: record.kBle), durable: false)
        let stored = try vault.load(on: thisMac)
        #expect(stored == .madeOnAnotherMac)
        #expect(!items.reads.contains(PairingVault.kBle), "the binding is checked before the key")
        #expect(PairingOpening.open(stored, sequences: file) == .unusable(
            .madeOnAnotherMac, detail: "hardware UUID differs or is not recorded"
        ), "even with a sequence state of its own")
        #expect(PairingUnusable.madeOnAnotherMac.rawValue == "made on another Mac")
    }

    @Test("a pairing without a recorded Mac, or a Mac whose UUID cannot be read, fails closed too")
    func unboundFailsClosed() throws {
        let items = MemoryItems()
        try items.write(record.peerFingerprint, to: PairingVault.peerPin)
        try items.write(record.kBle, to: PairingVault.kBle)
        let vault = PairingVault(items: items)
        #expect(try vault.load(on: thisMac) == .madeOnAnotherMac)
        try vault.save(record, on: thisMac)
        #expect(try vault.load(on: nil) == .madeOnAnotherMac)
        #expect(!items.reads.contains(PairingVault.kBle))
    }

    @Test("no pairing is none, whatever Mac asks")
    func nothingStored() throws {
        let vault = PairingVault(items: MemoryItems())
        #expect(try vault.load(on: thisMac) == .none)
        #expect(try vault.load(on: nil) == .none)
        #expect(PairingOpening.open(.none, sequences: temporaryFile()) == .none)
    }

    @Test("a pairing on this Mac still needs its own sequence state")
    func sequenceStateStillDecides() throws {
        let file = temporaryFile()
        #expect(PairingOpening.open(.found(record), sequences: file) == .unusable(.sequenceState, detail: "missing"))
        let fresh = SequenceState(fresh: record.kBle)
        try file.save(fresh, durable: false)
        #expect(PairingOpening.open(.found(record), sequences: file) == .usable(record, SequenceBook(fresh)))
    }

    @Test("unpairing removes every item, and wiping again is harmless")
    func wipe() throws {
        let items = MemoryItems()
        let vault = PairingVault(items: items)
        try vault.save(record, on: thisMac)
        #expect(items.accounts == [PairingVault.peerPin, PairingVault.kBle, PairingVault.host])
        try vault.wipe()
        try vault.wipe()
        #expect(items.accounts.isEmpty)
        #expect(try vault.load(on: thisMac) == StoredPairing.none)
    }
}
