import CoreBluetooth
import Foundation
import os

nonisolated enum GattEvent: Sendable {
    // The radio, the service, advertising or a subscription moved: read the machine again.
    case changed
    case frame(Data, central: UUID)
    case channel(L2capStreamPump)
}

// The CoreBluetooth shell of GattPeripheralMachine. It lives on the server's queue: the manager is
// created on it, so every callback arrives there in order with the server's own events, and the
// server reads and drives it synchronously. The manager — and with it the Bluetooth permission
// prompt — exists only while the bridge is enabled (paired or in pairing mode).
nonisolated final class BlePeripheral: NSObject {
    private let queue: DispatchSerialQueue
    private let events: @Sendable (GattEvent) -> Void
    private let log = Logger(subsystem: "app.cue.bridge", category: "ble")
    private var manager: CBPeripheralManager?
    private var command: CBMutableCharacteristic?
    // updateValue addresses centrals by object, the machine by identifier.
    private var subscribers: [UUID: CBCentral] = [:]
    // The centrals with an L2CAP channel open, counted by the server's links, which open and end them.
    private var channelPeers: [UUID: CBCentral] = [:]
    private var openChannels: [UUID: Int] = [:]
    private(set) var machine = GattPeripheralMachine()

    init(queue: DispatchSerialQueue, events: @escaping @Sendable (GattEvent) -> Void) {
        self.queue = queue
        self.events = events
    }

    func configure(enabled: Bool, paired: Bool) {
        carryOut(enabled ? machine.enable() : machine.disable())
        if enabled { carryOut(machine.setPaired(paired)) }
        events(.changed)
    }

    // False when the audience is empty or the frame does not fit its payload; the caller has checked
    // both, so that means the link just went.
    func notify(_ frame: Data, to audience: GattAudience) -> Bool {
        guard let dropped = machine.enqueue(frame, to: audience) else { return false }
        if dropped > 0 { log.info("ble notify queue full, \(dropped) oldest dropped") }
        drain()
        return true
    }

    // True when the intake confirmed the writer's subscription as the phone's; the caller then reads
    // the machine again.
    func received(_ intake: SignalIntake, from central: UUID) -> Bool {
        machine.received(intake, from: central)
    }

    func authenticated(_ central: UUID) -> Bool {
        machine.authenticated(central)
    }

    func revokeConfirmations() {
        machine.revokeConfirmations()
    }

    func channelChanged(_ peer: UUID, open: Bool) {
        let count = max(0, openChannels[peer, default: 0] + (open ? 1 : -1))
        openChannels[peer] = count == 0 ? nil : count
        if let central = channelPeers[peer] ?? subscribers[peer] { pace(central) }
        if count == 0 { channelPeers[peer] = nil }
    }

    // A held link costs least at high latency; a channel that carries a session asks for low latency
    // while it is open. CoreBluetooth treats either as a wish, and the phone asks for its own.
    private func pace(_ central: CBCentral) {
        guard let manager else { return }
        let transferring = openChannels[central.identifier] != nil
        manager.setDesiredConnectionLatency(transferring ? .low : .high, for: central)
        log.debug(
            "ble central \(Self.central(central), privacy: .public) desired latency \(transferring ? "low" : "high", privacy: .public)"
        )
    }

    private func drain() {
        guard let manager, let command else { return }
        while let next = machine.nextPending() {
            // Never an empty list: what CoreBluetooth does with one is not documented.
            let centrals = next.recipients.compactMap { subscribers[$0] }
            guard !centrals.isEmpty else { continue }
            guard manager.updateValue(next.frame, for: command, onSubscribedCentrals: centrals) else {
                machine.refused(next)
                log.debug("ble notify queued mac→phone \(Self.describe(next.frame), privacy: .public), waiting for the stack")
                return
            }
            log.debug(
                "ble notify sent mac→phone \(Self.describe(next.frame), privacy: .public) to \(centrals.count) of \(self.machine.centrals.count) centrals"
            )
        }
    }

    private func carryOut(_ effects: [GattPeripheralMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .createManager:
                log.info("ble peripheral starting; the first use asks for Bluetooth access")
                manager = CBPeripheralManager(delegate: self, queue: queue)
            case .addService(let psm):
                guard let manager else { continue }
                manager.removeAllServices()
                let doorbell = CBMutableCharacteristic(
                    type: BleService.doorbell, properties: [.write], value: nil, permissions: [.writeable]
                )
                let command = CBMutableCharacteristic(
                    type: BleService.command, properties: [.notify], value: nil, permissions: []
                )
                var characteristics = [doorbell, command]
                if let psm {
                    // A static value: CoreBluetooth answers the reads itself, so none reaches didReceiveRead.
                    var value = Data()
                    value.appendUInt16(psm)
                    characteristics.append(CBMutableCharacteristic(
                        type: BleService.psm, properties: [.read], value: value, permissions: [.readable]
                    ))
                }
                let service = CBMutableService(type: BleService.uuid, primary: true)
                service.characteristics = characteristics
                self.command = command
                log.info("ble service adding, \(psm.map { "psm \($0)" } ?? "no psm", privacy: .public)")
                manager.add(service)
            case .publishChannel:
                log.info("l2cap channel publishing, no link encryption")
                manager?.publishL2CAPChannel(withEncryption: false)
            case .unpublishChannel(let psm):
                log.info("l2cap channel unpublishing, psm \(psm)")
                manager?.unpublishL2CAPChannel(psm)
            case .startAdvertising:
                manager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [BleService.uuid]])
            case .teardown:
                if let manager {
                    manager.stopAdvertising()
                    manager.removeAllServices()
                    manager.delegate = nil
                }
                manager = nil
                command = nil
                subscribers = [:]
                channelPeers = [:]
                openChannels = [:]
                log.info("ble advertising stopped, service removed")
            }
        }
        subscribers = subscribers.filter { machine.centrals[$0.key] != nil }
    }

    private static func describe(_ frame: Data) -> String {
        guard frame.count >= SignalFrame.headerBytes else { return "bytes=\(frame.count)" }
        let frame = Data(frame)
        return "type=\(Signal.name(of: frame[0])) seq=\(frame.uint32(at: 1)) bytes=\(frame.count)"
    }

    private static func radio(_ state: CBManagerState) -> GattPeripheralMachine.Radio {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .resetting: .resetting
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    private static func authorization(_ value: CBManagerAuthorization) -> String {
        switch value {
        case .allowedAlways: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not determined"
        @unknown default: "unknown(\(value.rawValue))"
        }
    }

    private static func central(_ central: CBCentral) -> String {
        String(central.identifier.uuidString.prefix(8))
    }
}

// The class is nonisolated, but under the module's MainActor default isolation an unannotated
// extension would still make these MainActor — and CoreBluetooth calls them on the server's queue,
// which trips the runtime executor check and kills the app.
nonisolated extension BlePeripheral: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        let radio = Self.radio(peripheral.state)
        log.info(
            "ble radio \(radio.rawValue, privacy: .public), Bluetooth access \(Self.authorization(CBManager.authorization), privacy: .public)"
        )
        let wasSubscribed = machine.subscribed
        carryOut(machine.radio(radio))
        subscribers = subscribers.filter { machine.centrals[$0.key] != nil }
        if wasSubscribed, !machine.subscribed { log.info("ble central gone with the radio") }
        events(.changed)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard peripheral === manager else { return }
        if let error {
            log.error("ble service not added: \(error.localizedDescription, privacy: .public)")
        } else {
            log.debug("ble service added")
        }
        carryOut(machine.serviceAdded(error: error?.localizedDescription))
        events(.changed)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        guard peripheral === manager else { return }
        if let error {
            log.error("ble advertising failed: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("ble advertising started: service UUID only")
        }
        carryOut(machine.advertisingStarted(error: error?.localizedDescription))
        events(.changed)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, characteristic.uuid == BleService.command else { return }
        machine.subscribed(central.identifier, payload: central.maximumUpdateValueLength)
        if machine.centrals[central.identifier] != nil { subscribers[central.identifier] = central }
        log.info(
            "ble central \(Self.central(central), privacy: .public) subscribed, payload \(central.maximumUpdateValueLength) bytes"
        )
        pace(central)
        events(.changed)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard peripheral === manager, characteristic.uuid == BleService.command else { return }
        machine.unsubscribed(central.identifier)
        subscribers[central.identifier] = nil
        log.info("ble central \(Self.central(central), privacy: .public) unsubscribed")
        events(.changed)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        guard peripheral === manager else { return }
        drain()
    }

    // CoreBluetooth answers a batch of writes once, through its first request, and the result
    // stands for all of them. The ATT response confirms delivery only: what the frames are worth is
    // decided by the receiving rules afterwards, and a failing frame is dropped silently there.
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard peripheral === manager, let first = requests.first else { return }
        let result: CBATTError.Code
        if requests.contains(where: { $0.characteristic.uuid != BleService.doorbell }) {
            result = .writeNotPermitted
        } else if requests.contains(where: { $0.offset != 0 }) {
            result = .invalidOffset
        } else if requests.contains(where: { ($0.value ?? Data()).isEmpty }) {
            result = .invalidAttributeValueLength
        } else {
            result = .success
        }
        peripheral.respond(to: first, withResult: result)
        guard result == .success else {
            log.debug("ble write dropped phone→Mac: \(requests.count) requests answered \(result.rawValue)")
            return
        }
        for request in requests {
            guard let value = request.value else { continue }
            log.debug(
                "ble doorbell write phone→Mac central=\(Self.central(request.central), privacy: .public) \(Self.describe(value), privacy: .public)"
            )
            events(.frame(value, central: request.central.identifier))
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        guard peripheral === manager else { return }
        if let error {
            log.error("l2cap channel not published: \(error.localizedDescription, privacy: .public)")
        } else {
            log.info("l2cap channel published, psm \(PSM)")
        }
        carryOut(machine.channelPublished(psm: PSM, error: error?.localizedDescription))
        events(.changed)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didUnpublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        guard peripheral === manager else { return }
        if let error {
            log.debug("l2cap channel psm \(PSM) unpublish: \(error.localizedDescription, privacy: .public)")
        } else {
            log.debug("l2cap channel psm \(PSM) unpublished")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard peripheral === manager else { return }
        guard let channel, error == nil else {
            log.info("l2cap channel failed to open: \(error?.localizedDescription ?? "no channel", privacy: .public)")
            return
        }
        log.info(
            "l2cap channel opened by \(String(channel.peer.identifier.uuidString.prefix(8)), privacy: .public) on psm \(channel.psm)"
        )
        if let central = channel.peer as? CBCentral { channelPeers[central.identifier] = central }
        events(.channel(L2capStreamPump(channel: channel)))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard peripheral === manager else { return }
        peripheral.respond(to: request, withResult: .readNotPermitted)
    }
}
