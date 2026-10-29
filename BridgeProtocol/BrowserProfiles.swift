import Foundation

nonisolated struct BrowserProfile: Codable, Hashable, Sendable {
    var bundleID: String
    var directory: String
}

nonisolated struct ChromiumBrowser: Sendable {
    var bundleID: String
    var name: String
    // Under ~/Library/Application Support.
    var dataPath: String

    static let known: [ChromiumBrowser] = [
        ChromiumBrowser(bundleID: "com.google.Chrome", name: "Google Chrome", dataPath: "Google/Chrome"),
        ChromiumBrowser(bundleID: "com.google.Chrome.beta", name: "Google Chrome Beta", dataPath: "Google/Chrome Beta"),
        ChromiumBrowser(bundleID: "com.google.Chrome.dev", name: "Google Chrome Dev", dataPath: "Google/Chrome Dev"),
        ChromiumBrowser(bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary", dataPath: "Google/Chrome Canary"),
        ChromiumBrowser(bundleID: "org.chromium.Chromium", name: "Chromium", dataPath: "Chromium"),
        ChromiumBrowser(bundleID: "com.brave.Browser", name: "Brave", dataPath: "BraveSoftware/Brave-Browser"),
        ChromiumBrowser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", dataPath: "Microsoft Edge"),
        ChromiumBrowser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", dataPath: "Vivaldi"),
    ]

    static func named(_ bundleID: String) -> ChromiumBrowser? {
        known.first { $0.bundleID == bundleID }
    }

    // macOS 27 keeps an app from reading or listing another app's data, not from looking a path up
    // by name, so the profiles are found as the folders Chromium names them. One that does not exist
    // must never reach the browser: Chromium creates an empty profile for any name it is given.
    static let profileDirectories = ["Default"] + (1...100).map { "Profile \($0)" }
}
