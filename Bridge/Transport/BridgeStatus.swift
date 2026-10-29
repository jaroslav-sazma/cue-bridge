import Foundation

nonisolated struct BridgeStatus: Equatable, Sendable {
    enum Listener: Equatable, Sendable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    enum Bonjour: Equatable, Sendable {
        case off
        case registering
        case advertised(name: String)
    }

    // `waiting` is pairing mode open for a phone; `verifying` holds the phone's commitment until it
    // reveals its key; `enteringCode` waits for this Mac's user to type the phone's code;
    // `codeAccepted` waits for the phone's proof, which it sends right after its reveal, so only a code
    // typed faster than that arrives ever shows it.
    enum Pairing: Equatable, Sendable {
        case idle
        case preparing
        case waiting(expiresAt: Date)
        case verifying
        case enteringCode(rejected: Int)
        case codeAccepted
        case committed(macFingerprint: Data?)
        case aborted(String)
        case failed(String)

        var isInProgress: Bool {
            switch self {
            case .preparing, .waiting, .verifying, .enteringCode, .codeAccepted: true
            default: false
            }
        }
    }

    enum Connection: Equatable, Sendable {
        case none
        case pairing(endpoint: String)
        case session(endpoint: String, transport: LinkTransport)
    }

    struct StateSync: Equatable, Sendable {
        var count: Int
        var added: Int
        var updated: Int
        var removed: Int
        var untouched: Int
        var at: Date
    }

    enum Bluetooth: Equatable, Sendable {
        case off
        case starting
        case advertising
        // Powered off, unauthorized, unsupported or resetting.
        case unavailable(GattPeripheralMachine.Radio)
        case failed(String)
    }

    struct GattTraffic: Equatable, Sendable {
        var type: String
        var at: Date
    }

    var peerFingerprint: Data?
    // A stored pairing made on another Mac, or whose sequence state is missing, unreadable or another
    // key's: nothing is sent or accepted under it until the phone is paired again or unpaired.
    var pairingUnusable: PairingUnusable?
    var listener = Listener.stopped
    var bonjour = Bonjour.off
    var bonjourPairFlag = false
    var pairing = Pairing.idle
    var connection = Connection.none
    var lastStateSync: StateSync?
    var mirroredCount = 0
    var storageError: String?
    var bluetooth = Bluetooth.off
    // The notification payload frames are sized for while paired, nil with no subscriber at or above
    // the floor. Only `bluetoothConfirmed` makes it the phone's.
    var bluetoothPayload: Int?
    var bluetoothConfirmed = false
    var l2cap = GattPeripheralMachine.Channel.idle
    var lastGattSent: GattTraffic?
    var lastGattReceived: GattTraffic?

    var peerFingerprintPrefix: String? {
        peerFingerprint.map(Self.prefix)
    }

    var macFingerprintPrefix: String? {
        if case .committed(let fingerprint) = pairing { fingerprint.map(Self.prefix) } else { nil }
    }

    private static func prefix(_ fingerprint: Data) -> String {
        String(fingerprint.hex.prefix(8))
    }

    var phoneNearby: Bool { bluetoothConfirmed }

    // Without the advertisement the phone cannot tell that this Mac is nearby.
    var bluetoothProblem: String? {
        switch bluetooth {
        case .off, .starting, .advertising: nil
        case .unavailable(.poweredOff): "Bluetooth is off"
        case .unavailable(.unauthorized): "Bluetooth access is not allowed"
        case .unavailable(.unsupported): "Bluetooth is not supported"
        case .unavailable: nil
        case .failed: "Bluetooth is not working"
        }
    }

    var menuBar: MenuBarState {
        let connected = if case .session = connection { true } else { false }
        return MenuBarState(
            paired: peerFingerprint != nil, unusable: pairingUnusable != nil, connected: connected,
            storageError: storageError != nil, bluetoothProblem: bluetoothProblem != nil
        )
    }
}
