import AppKit
import os

enum InstalledBrowsers {
    private static let log = Logger(subsystem: "app.cue.bridge", category: "clicks")

    static func profiles() -> [BrowserProfile] {
        ChromiumBrowser.known.filter { appURL($0.bundleID) != nil }.flatMap { browser in
            ChromiumBrowser.profileDirectories
                .filter { exists($0, of: browser) }
                .map { BrowserProfile(bundleID: browser.bundleID, directory: $0) }
        }
    }

    private static func exists(_ directory: String, of browser: ChromiumBrowser) -> Bool {
        let path = URL.applicationSupportDirectory
            .appending(path: browser.dataPath, directoryHint: .isDirectory)
            .appending(path: directory, directoryHint: .isDirectory)
            .path(percentEncoded: false)
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    // A running browser takes no arguments from Launch Services, so a new instance carries them: it
    // hands the URL and the profile to the one already running and quits, possibly before Launch
    // Services reports it launched. So with a browser running, the launch stays in the background,
    // its error counts as delivered, and focus goes to the copy that was running.
    static func open(_ url: URL, in profile: BrowserProfile) async -> Bool {
        guard let browser = ChromiumBrowser.named(profile.bundleID), let app = appURL(profile.bundleID),
              ChromiumBrowser.profileDirectories.contains(profile.directory), exists(profile.directory, of: browser)
        else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: profile.bundleID)
            .first { !$0.isTerminated }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = running == nil
        configuration.arguments = ["--profile-directory=\(profile.directory)", url.absoluteString]
        if let running { NSApp.yieldActivation(to: running) }
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } catch {
            let error = error as NSError
            log.info("browser launch failed: \(error.domain, privacy: .public) \(error.code, privacy: .public)")
            guard running != nil else { return false }
        }
        running?.activate()
        log.info("click link handed to \(profile.bundleID, privacy: .public) profile \(profile.directory, privacy: .public)")
        return true
    }
}
