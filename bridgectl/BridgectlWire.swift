import Foundation

// The debug socket between the app and bridgectl: one JSON request line, one JSON response line.
// It is internal to this repo and not part of the bridge protocol.
nonisolated enum BridgectlWire {
    static var socketURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Cue Bridge", directoryHint: .isDirectory)
            .appending(path: "debug", directoryHint: .isDirectory)
            .appending(path: "bridgectl.sock")
    }

    struct Request: Codable, Sendable {
        var command: String
    }

    struct Status: Codable, Sendable {
        var protocolVersion: Int
        var paired: Bool
        var pairingUnusable: Bool?
        var pairingUnusableReason: String?
        var peerFingerprintPrefix: String?
        var pairingMode: String
        var listener: String
        var listenerPort: Int?
        var bonjour: String
        var bonjourName: String?
        var bonjourPairFlag: Bool?
        var connection: String
        var sessionTransport: String?
        var peerEndpoint: String?
        var lastStateSyncCount: Int?
        var lastStateSyncAt: Date?
        var lastStateSyncAdded: Int?
        var lastStateSyncUpdated: Int?
        var lastStateSyncRemoved: Int?
        var lastStateSyncUntouched: Int?
        var mirroredCount: Int
        var storageError: String?
        var reconcilerMode: String?
        var reconcilerIntervalSeconds: Int?
        var reconcilerArmed: Bool?
        var reconcilerIdle: String?
        var bluetooth: String?
        var bluetoothPayload: Int?
        var bluetoothConfirmed: Bool?
        var l2cap: String?
        var l2capPsm: Int?
        var lastGattSentType: String?
        var lastGattSentAt: Date?
        var lastGattReceivedType: String?
        var lastGattReceivedAt: Date?
    }

    // Debug builds only, over the owner-only socket: the content is shown so fixtures can be checked.
    struct MirrorRow: Codable, Sendable {
        var keyHash: String
        var pkg: String
        var threadIdentifier: String
        var hasIcon: Bool
        var pending: Bool
        var title: String
        var body: String
    }

    // Metadata only, never clip text.
    struct ClipRow: Codable, Sendable {
        var direction: String
        var type: String
        var bytes: Int
        var sensitive: Bool
        var announce: Bool
        var at: Date
    }

    struct Clipboard: Codable, Sendable {
        var publisher: String
        var idle: String?
        var intervalSeconds: Int
        var accessBehavior: String
        var changeCount: Int?
        var lastSent: ClipRow?
        var lastReceived: ClipRow?
        var lastSkipped: String?
        var lastSkippedAt: Date?
        var tombstones: Int
    }

    struct Response: Codable, Sendable {
        var status: Status?
        var mirror: [MirrorRow]?
        var clipboard: Clipboard?
        var error: String?
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
