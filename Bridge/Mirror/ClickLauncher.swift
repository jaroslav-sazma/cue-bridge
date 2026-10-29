import AppKit

enum ClickLauncher {
    // False when there is nothing to open: an app no longer installed, a link no app handles, a
    // browser profile gone.
    static func perform(_ action: ClickAction) async -> Bool {
        switch action {
        case .openLink(let link, let profile):
            guard let url = URL(string: link) else { return false }
            guard let profile, ClickLink.isWeb(link) else { return NSWorkspace.shared.open(url) }
            return await InstalledBrowsers.open(url, in: profile)
        case .launchApp(let bundleID, _):
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                return true
            } catch {
                return false
            }
        // ClickRoutes.resolve answers an explicit reminder with nil and turns the library's default
        // into what it opens, so neither reaches here.
        case .showReminder, .libraryDefault:
            return false
        }
    }

    static func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
