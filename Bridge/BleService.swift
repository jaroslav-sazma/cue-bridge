import CoreBluetooth

nonisolated enum BleService {
    // The phone's companion-device association filters its scan by this advertised UUID, so the
    // Mac's presence depends on it as much as the GATT link does.
    static var uuid: CBUUID { CBUUID(string: BridgeProtocol.gattService) }
    static var doorbell: CBUUID { CBUUID(string: BridgeProtocol.gattDoorbell) }
    static var command: CBUUID { CBUUID(string: BridgeProtocol.gattCommand) }
    static var psm: CBUUID { CBUUID(string: BridgeProtocol.gattPsm) }
}
