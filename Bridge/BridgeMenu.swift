import SwiftUI

struct BridgeMenu: View {
    let bridge: BridgeController

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Section("Phone") {
            if let prefix = bridge.status.peerFingerprintPrefix {
                Text("Paired with phone \(prefix)")
                Text(connectionLabel)
                Text("Mirrored: \(bridge.status.mirroredCount)")
            } else if let unusable = bridge.status.pairingUnusable {
                switch unusable {
                case .sequenceState:
                    Text("Pairing unusable: its sequence state is lost")
                    Text("Pair again to use the bridge")
                case .madeOnAnotherMac:
                    Text("Pairing was made on another Mac — pair again")
                }
            } else {
                Text("Not paired")
            }
            if let problem = bridge.status.bluetoothProblem {
                Text(problem)
            }
            if let error = bridge.status.storageError {
                Text(error)
            }
        }
        Section {
            Button(
                bridge.hasStoredPairing ? "Pair Again…" : "Pair Phone…", systemImage: "link.badge.plus"
            ) {
                bridge.startPairing()
                openWindow(id: PairingWindow.id)
                NSApplication.shared.activate()
            }
            if bridge.hasStoredPairing {
                Button("Unpair", systemImage: "minus.circle") { bridge.unpair() }
            }
        }
        // SettingsLink has no hook for activating the app, and a menu-bar app is not active while its
        // menu is open, so the window would open behind the frontmost app's.
        Section {
            Button("Settings…", systemImage: "gearshape") {
                openSettings()
                NSApplication.shared.activate()
            }
            .keyboardShortcut(",")
        }
        #if DEBUG
        Section("Debug") {
            Menu("Bridge Debug") {
                Text("Listener: \(listenerLabel)")
                Text("Bonjour: \(bonjourLabel)")
                Text("Bluetooth: \(bluetoothLabel)")
                Button("Send sync-request") { bridge.requestSync() }
                Button("Send sync-request signal") { bridge.sendSignal(.syncRequest) }
            }
        }
        #endif
        Section {
            // The panel names the app by CFBundleName, which is the colon-free file name.
            Button("About Cue:", systemImage: "info.circle") {
                NSApplication.shared.orderFrontStandardAboutPanel(
                    options: [.applicationName: Bundle.main.displayName ?? "Cue:"]
                )
                NSApplication.shared.activate()
            }
            Button("Quit Cue:", systemImage: "power") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private var connectionLabel: String {
        switch bridge.status.connection {
        case .none: bridge.status.phoneNearby ? "Phone nearby (Bluetooth)" : "Phone not connected"
        case .pairing: "Pairing in progress"
        case .session: "Phone connected"
        }
    }

    #if DEBUG
    private var listenerLabel: String {
        switch bridge.status.listener {
        case .stopped: "stopped"
        case .starting: "starting"
        case .ready(let port): "port \(port)"
        case .failed(let error): "failed (\(error))"
        }
    }

    private var bonjourLabel: String {
        switch bridge.status.bonjour {
        case .off: "off"
        case .registering: "registering"
        case .advertised(let name): name
        }
    }

    private var bluetoothLabel: String {
        let subscription = bridge.status.bluetoothPayload.map {
            bridge.status.bluetoothConfirmed ? ", phone confirmed (\($0) bytes)" : ", subscriber not confirmed (\($0) bytes)"
        } ?? ""
        return switch bridge.status.bluetooth {
        case .off: "off"
        case .starting: "starting"
        case .advertising: "advertising" + subscription
        case .unavailable(let radio): radio.rawValue
        case .failed(let error): "failed (\(error))"
        }
    }
    #endif
}
