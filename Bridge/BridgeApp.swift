import SwiftUI

@main
struct BridgeApp: App {
    @State private var bridge: BridgeController
    @State private var loginItem: LoginItem

    // Property initializers would run before this body, so the state is built only after the check.
    init() {
        SingleInstance.exitIfAnotherRuns()
        _bridge = State(initialValue: BridgeController())
        _loginItem = State(initialValue: LoginItem())
    }

    var body: some Scene {
        MenuBarExtra {
            BridgeMenu(bridge: bridge)
        } label: {
            MenuBarLabel(bridge: bridge)
        }
        Window("Pair Phone", id: PairingWindow.id) {
            PairingWindow(bridge: bridge)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        Settings {
            SettingsView(bridge: bridge, loginItem: loginItem)
        }
        .windowResizability(.contentMinSize)
    }
}

// SwiftUI opens the Settings scene only through a view's openSettings, so the one view alive for as
// long as the app runs carries out the requests that come from outside any view (NotificationRouter).
private struct MenuBarLabel: View {
    let bridge: BridgeController

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Label("Cue:", systemImage: bridge.menuBar.symbol)
            .accessibilityValue(menuBarValue)
            .onChange(of: bridge.clicks.settingsRequests) {
                openSettings()
                NSApplication.shared.activate()
            }
    }

    private var menuBarValue: String {
        switch bridge.menuBar {
        case .notPaired: "Not paired"
        case .idle: "Phone not connected"
        case .connected: "Phone connected"
        case .problem: "Needs attention"
        }
    }
}
