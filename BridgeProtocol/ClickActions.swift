import Foundation

nonisolated enum ClickAction: Codable, Equatable, Sendable {
    // A web link with a browser profile opens only in that profile, never elsewhere.
    case openLink(String, in: BrowserProfile? = nil)
    case launchApp(bundleID: String, name: String)
    // Stored per app, it stops both the library's default and the fallback.
    case showReminder
    // Stored per app only: the library's default, a web link of which opens in this profile. Which
    // one the default is gets decided at the click; a Mac app ignores the profile.
    case libraryDefault(in: BrowserProfile)

    enum Kind: String, Sendable {
        case link, app, reminder, defaultLink
    }

    // A profile applies to web links only; any other scheme opens in the app that handles it.
    static func link(_ url: String, in profile: BrowserProfile?) -> ClickAction {
        .openLink(url, in: ClickLink.isWeb(url) ? profile : nil)
    }

    var kind: Kind {
        switch self {
        case .openLink: .link
        case .launchApp: .app
        case .showReminder: .reminder
        case .libraryDefault: .defaultLink
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, url, browser, bundleID, name
    }

    // A kind of its own, so a build that predates profiles drops the action rather than open the
    // link in the default browser.
    private static let profileLinkKind = "profileLink"

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        if kind == Self.profileLinkKind {
            self = .openLink(
                try container.decode(String.self, forKey: .url),
                in: try container.decode(BrowserProfile.self, forKey: .browser)
            )
            return
        }
        switch Kind(rawValue: kind) {
        case .link:
            self = .openLink(try container.decode(String.self, forKey: .url))
        case .app:
            self = .launchApp(
                bundleID: try container.decode(String.self, forKey: .bundleID),
                name: try container.decode(String.self, forKey: .name)
            )
        case .reminder:
            self = .showReminder
        case .defaultLink:
            self = .libraryDefault(in: try container.decode(BrowserProfile.self, forKey: .browser))
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "unknown click action \(kind)"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .openLink(let url, let browser):
            try container.encode(browser == nil ? kind.rawValue : Self.profileLinkKind, forKey: .kind)
            try container.encode(url, forKey: .url)
            try container.encodeIfPresent(browser, forKey: .browser)
        case .launchApp(let bundleID, let name):
            try container.encode(kind.rawValue, forKey: .kind)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(name, forKey: .name)
        case .showReminder:
            try container.encode(kind.rawValue, forKey: .kind)
        case .libraryDefault(let browser):
            try container.encode(kind.rawValue, forKey: .kind)
            try container.encode(browser, forKey: .browser)
        }
    }
}

nonisolated enum DefaultClick: Equatable, Sendable {
    case library(ClickAction)
    case fallback(ClickAction)
    case reminder

    var takesBrowserProfile: Bool {
        guard case .library(.openLink(let url, _)) = self else { return false }
        return ClickLink.isWeb(url)
    }
}

nonisolated struct ClickRoutes: Codable, Equatable, Sendable {
    var perApp: [String: ClickAction] = [:]
    var fallback: ClickAction?
    // What Default Browser means: a web link without a profile of its own opens in this one, and
    // like any profile only there. Nil is the system's default browser.
    var defaultBrowser: BrowserProfile?

    var configured: Set<String> { Set(perApp.keys) }

    // What an app left at Default does, its profile for the library's web link applied. The settings
    // caption and profile picker read it too, so they can never disagree with the click.
    func byDefault(_ pkg: String, library: ClickLibrary, installed: (String) -> Bool) -> DefaultClick {
        if let action = library.action(for: pkg, installed: installed) {
            let own: BrowserProfile? = if case .libraryDefault(let profile) = perApp[pkg] { profile } else { nil }
            return .library(inBrowser(action, own ?? defaultBrowser))
        }
        switch fallback {
        case nil, .showReminder, .libraryDefault: return .reminder
        case let fallback?: return .fallback(inBrowser(fallback, defaultBrowser))
        }
    }

    // Nil shows the reminder; .showReminder and .libraryDefault never come out.
    func resolve(_ pkg: String, library: ClickLibrary, installed: (String) -> Bool) -> ClickAction? {
        switch perApp[pkg] {
        case .showReminder: nil
        case nil, .libraryDefault:
            switch byDefault(pkg, library: library, installed: installed) {
            case .library(let action), .fallback(let action): action
            case .reminder: nil
            }
        case let own?: inBrowser(own, defaultBrowser)
        }
    }

    private func inBrowser(_ action: ClickAction, _ profile: BrowserProfile?) -> ClickAction {
        guard case .openLink(let url, nil) = action else { return action }
        return .link(url, in: profile)
    }
}

nonisolated struct PhoneApp: Codable, Equatable, Sendable {
    var pkg: String
    var label: String
    var iconHash: String?

    init(pkg: String, label: String, iconHash: String?) {
        self.pkg = pkg
        self.label = label
        self.iconHash = iconHash
    }

    init(_ info: NotificationInfo) {
        self.init(pkg: info.pkg, label: info.appLabel, iconHash: info.iconHash)
    }

    var displayName: String { label.isEmpty ? pkg : label }

    // Carried by the reminder notice, so its "Set Click Action…" button knows the app.
    static let marker = "cue.click-app"

    var userInfo: [String: Any] {
        var info: [String: Any] = [Self.marker: 1, "pkg": pkg, "appLabel": label]
        if let iconHash { info["iconHash"] = iconHash }
        return info
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard (userInfo[Self.marker] as? Int) == 1, let pkg = userInfo["pkg"] as? String, !pkg.isEmpty,
              let label = userInfo["appLabel"] as? String
        else { return nil }
        self.init(pkg: pkg, label: label, iconHash: userInfo["iconHash"] as? String)
    }
}

// The phone apps whose notifications were mirrored, for the settings to offer. Capped, the oldest
// sighting going first — except an app with an action of its own, which would otherwise keep acting
// with no row left to change it.
nonisolated struct SeenApps: Codable, Equatable, Sendable {
    static let cap = 30
    // A sighting that only moves lastSeen by less than this is not worth a write.
    static let refresh: TimeInterval = 60

    struct Sighting: Codable, Equatable, Sendable, Identifiable {
        var app: PhoneApp
        var lastSeen: Date

        var id: String { app.pkg }
    }

    private(set) var sightings: [String: Sighting] = [:]

    mutating func record(_ app: PhoneApp, at date: Date, keeping configured: Set<String>) {
        guard !app.pkg.isEmpty else { return }
        var app = app
        if app.iconHash == nil { app.iconHash = sightings[app.pkg]?.app.iconHash }
        sightings[app.pkg] = Sighting(app: app, lastSeen: date)
        while sightings.count > Self.cap {
            let prunable = sightings.values.filter { $0.app.pkg != app.pkg && !configured.contains($0.app.pkg) }
            guard let oldest = prunable.min(by: { ($0.lastSeen, $0.app.pkg) < ($1.lastSeen, $1.app.pkg) }) else { break }
            sightings[oldest.app.pkg] = nil
        }
    }

    func differs(from old: SeenApps) -> Bool {
        guard sightings.count == old.sightings.count else { return true }
        return sightings.contains { pkg, sighting in
            guard let before = old.sightings[pkg], before.app == sighting.app else { return true }
            return abs(sighting.lastSeen.timeIntervalSince(before.lastSeen)) >= Self.refresh
        }
    }

    var ordered: [Sighting] {
        sightings.values.sorted { a, b in
            switch a.app.displayName.compare(b.app.displayName, options: .caseInsensitive) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.app.pkg < b.app.pkg
            }
        }
    }
}

nonisolated enum ClickStorage {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try? encoder.encode(value)
    }

    // Unreadable data reads as nothing stored.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data?) -> T? {
        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(type, from: data)
    }

    // Entry by entry, so one action this build cannot read (a kind from a newer build) drops only
    // itself. Nil when the whole is unreadable.
    static func decodeRoutes(from data: Data?) -> (routes: ClickRoutes, dropped: Int)? {
        guard let stored = decode(StoredRoutes.self, from: data) else { return nil }
        let perApp = (stored.perApp ?? [:]).compactMapValues(\.value)
        let fallback = stored.fallback?.value
        let defaultBrowser = stored.defaultBrowser?.value
        let dropped = (stored.perApp?.count ?? 0) - perApp.count + (stored.fallback != nil && fallback == nil ? 1 : 0)
            + (stored.defaultBrowser != nil && defaultBrowser == nil ? 1 : 0)
        return (ClickRoutes(perApp: perApp, fallback: fallback, defaultBrowser: defaultBrowser), dropped)
    }

    private struct StoredRoutes: Decodable {
        var perApp: [String: Lenient<ClickAction>]?
        var fallback: Lenient<ClickAction>?
        var defaultBrowser: Lenient<BrowserProfile>?
    }

    private struct Lenient<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}

nonisolated enum ClickLink {
    // A string without a scheme is taken for a web address. http and https need a host and a port
    // in range; any other scheme (slack://open, mailto:, tel:) only something after its colon.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = explicitScheme(trimmed) == nil ? "https://\(trimmed)" : trimmed
        guard URL(string: candidate) != nil, let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { return nil }
            if let port = components.port, !(0...65535).contains(port) { return nil }
        } else if candidate.dropFirst(scheme.count + 1).isEmpty {
            return nil
        }
        return candidate
    }

    static func isWeb(_ link: String) -> Bool {
        guard let scheme = URLComponents(string: link)?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // "example.com:8080" and "localhost:8080" parse as a scheme followed by a path; both are a host.
    // A name without a dot is a scheme even before digits (tel:5551234), localhost excepted.
    private static func explicitScheme(_ string: String) -> Substring? {
        guard let colon = string.firstIndex(of: ":") else { return nil }
        let scheme = string[..<colon]
        let rest = string[string.index(after: colon)...]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        if rest.hasPrefix("//") { return scheme }
        if scheme.contains(".") { return nil }
        if scheme.lowercased() == "localhost" {
            let port = rest.prefix { !"/?#".contains($0) }
            if !port.isEmpty, port.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }
        }
        return scheme
    }
}
