import Foundation

nonisolated struct PairingRecord: Equatable, Sendable {
    var peerFingerprint: Data
    var kBle: Data
}

// One secret per account. A delete of an item that is not there succeeds.
nonisolated protocol SecretItems: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, to account: String) throws
    func delete(_ account: String) throws
}

nonisolated enum StoredPairing: Equatable, Sendable {
    case none
    case madeOnAnotherMac
    case found(PairingRecord)
}

// The pairing is bound to the hardware UUID of the Mac it was made on. A keychain that reaches
// another Mac — migrated, restored — would otherwise carry K_ble and its live counters to a second
// sender under the same key. The binding is read before the key, so a foreign pairing never loads
// its key at all; a pairing without a binding counts as foreign.
nonisolated struct PairingVault: Sendable {
    static let peerPin = "peer-pin"
    static let kBle = "k-ble"
    static let host = "pairing-host"

    let items: any SecretItems

    func load(on host: String?) throws -> StoredPairing {
        guard let pin = try items.read(Self.peerPin) else { return .none }
        let bound = try items.read(Self.host).flatMap { String(data: $0, encoding: .utf8) }
        guard let host, bound == host else { return .madeOnAnotherMac }
        guard let kBle = try items.read(Self.kBle) else { return .none }
        return .found(PairingRecord(peerFingerprint: pin, kBle: kBle))
    }

    func save(_ record: PairingRecord, on host: String) throws {
        try items.write(Data(host.utf8), to: Self.host)
        try items.write(record.peerFingerprint, to: Self.peerPin)
        try items.write(record.kBle, to: Self.kBle)
    }

    func wipe() throws {
        for account in [Self.peerPin, Self.kBle, Self.host] {
            try items.delete(account)
        }
    }
}

nonisolated enum PairingUnusable: String, Equatable, Sendable {
    case sequenceState = "sequence state lost"
    case madeOnAnotherMac = "made on another Mac"
}

nonisolated enum PairingOpening: Equatable, Sendable {
    case none
    case usable(PairingRecord, SequenceBook)
    case unusable(PairingUnusable, detail: String)

    // Fail closed: without its own sequence state a stored key would have to count from zero again,
    // which reuses nonces and reopens every replay, so it stays unloaded until the next pairing.
    static func open(_ stored: StoredPairing, sequences: SequenceFile) -> PairingOpening {
        switch stored {
        case .none:
            return .none
        case .madeOnAnotherMac:
            return .unusable(.madeOnAnotherMac, detail: "hardware UUID differs or is not recorded")
        case .found(let record):
            switch sequences.load(for: record.kBle) {
            case .usable(let book): return .usable(record, book)
            case .unusable(let reason): return .unusable(.sequenceState, detail: reason)
            }
        }
    }
}
