import Observation
import ServiceManagement
import os

@Observable
final class LoginItem {
    private(set) var isEnabled = false

    @ObservationIgnored
    private let logger = Logger(subsystem: "app.cue.bridge", category: "login-item")

    init() {
        refresh()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        // register() also succeeds when the user has switched the item off in System Settings, but
        // leaves it there awaiting approval; only the user can turn it back on, in that pane.
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        // macOS can keep the System Settings "Allow in Background" row for a running menu-bar app
        // after unregister() returns; this records what SMAppService actually reports so a stale row
        // can be told apart from an unregister that did not take.
        logger.notice("login item set to \(enabled, privacy: .public); status now \(self.statusName, privacy: .public)")
        refresh()
    }

    private var statusName: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown"
        }
    }

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
