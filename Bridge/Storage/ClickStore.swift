import Foundation
import Observation
import os

// The click actions are the user's own and, like MacSwitches, kept across pairings; the seen apps
// come from the phone and go with its pairing.
@Observable
final class ClickStore {
    private static let routesKey = "clickRoutes"
    private static let seenKey = "clickSeenApps"

    private(set) var routes: ClickRoutes
    private(set) var seen: SeenApps
    @ObservationIgnored let library: ClickLibrary
    // The app the settings are to show first; the settings clear it once shown.
    var focus: String?
    private(set) var settingsRequests = 0

    // Stored actions this build cannot read at all are left alone rather than overwritten, until a
    // read succeeds.
    @ObservationIgnored private var routesWritable: Bool
    @ObservationIgnored private let log = Logger(subsystem: "app.cue.bridge", category: "clicks")

    init() {
        let defaults = UserDefaults.standard
        let stored = defaults.data(forKey: Self.routesKey)
        if let decoded = ClickStorage.decodeRoutes(from: stored) {
            routes = decoded.routes
            routesWritable = true
            if decoded.dropped > 0 {
                log.info("click settings: \(decoded.dropped) unreadable entries dropped, \(decoded.routes.perApp.count) app actions kept")
            }
        } else {
            routes = ClickRoutes()
            routesWritable = stored == nil
            if stored != nil { log.info("click actions unreadable, none in effect, the stored ones left as they are") }
        }
        seen = ClickStorage.decode(SeenApps.self, from: defaults.data(forKey: Self.seenKey)) ?? SeenApps()
        library = Self.loadLibrary(log: log)
    }

    private static func loadLibrary(log: Logger) -> ClickLibrary {
        guard let url = Bundle.main.url(forResource: "ClickLibrary", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else {
            log.error("click library missing from the app, no defaults in effect")
            return ClickLibrary()
        }
        guard let decoded = ClickLibrary.decode(from: data) else {
            log.error("click library unreadable, no defaults in effect")
            return ClickLibrary()
        }
        if decoded.dropped > 0 {
            log.error("click library: \(decoded.dropped) malformed or repeated entries dropped, \(decoded.library.entries.count) kept")
        }
        return decoded.library
    }

    func action(for pkg: String) -> ClickAction? {
        routes.resolve(pkg, library: library, installed: ClickLauncher.isInstalled)
    }

    func byDefault(_ pkg: String, installed: (String) -> Bool) -> DefaultClick {
        routes.byDefault(pkg, library: library, installed: installed)
    }

    func set(_ action: ClickAction?, for pkg: String) {
        guard routes.perApp[pkg] != action else { return }
        routes.perApp[pkg] = action
        saveRoutes()
    }

    func setFallback(_ action: ClickAction?) {
        guard routes.fallback != action else { return }
        routes.fallback = action
        saveRoutes()
    }

    func setDefaultBrowser(_ profile: BrowserProfile?) {
        guard routes.defaultBrowser != profile else { return }
        routes.defaultBrowser = profile
        saveRoutes()
    }

    private func saveRoutes() {
        let defaults = UserDefaults.standard
        if !routesWritable {
            let stored = defaults.data(forKey: Self.routesKey)
            guard stored == nil || ClickStorage.decodeRoutes(from: stored) != nil else {
                log.info("click action changed for this run only: the stored ones are unreadable")
                return
            }
            routesWritable = true
        }
        defaults.set(ClickStorage.encode(routes), forKey: Self.routesKey)
    }

    func saw(_ apps: [PhoneApp]) {
        guard !apps.isEmpty else { return }
        var next = seen
        let now = Date.now
        for app in apps {
            next.record(app, at: now, keeping: routes.configured)
        }
        guard next.differs(from: seen) else { return }
        seen = next
        UserDefaults.standard.set(ClickStorage.encode(seen), forKey: Self.seenKey)
    }

    func forgetSeen() {
        seen = SeenApps()
        UserDefaults.standard.removeObject(forKey: Self.seenKey)
    }

    // The app is recorded again: the seen apps may have pruned it since its notice was posted.
    func requestSettings(for app: PhoneApp?) {
        if let app {
            saw([app])
            focus = app.pkg
        }
        settingsRequests += 1
    }
}
