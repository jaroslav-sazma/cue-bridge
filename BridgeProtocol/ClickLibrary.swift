import Foundation

// Only the package name picks an entry; nothing from a notification ever goes into a link.
nonisolated struct ClickLibrary: Equatable, Sendable {
    struct MacApp: Codable, Equatable, Sendable {
        var bundleID: String
        var name: String
    }

    struct Entry: Equatable, Sendable {
        var pkg: String
        var web: String?
        var mac: [MacApp] = []
    }

    let entries: [Entry]
    private let byPkg: [String: Entry]

    // A package listed twice keeps its first entry.
    init(entries: [Entry] = []) {
        self.entries = entries
        byPkg = Dictionary(entries.map { ($0.pkg, $0) }, uniquingKeysWith: { first, _ in first })
    }

    var bundleIDs: Set<String> { Set(entries.flatMap { $0.mac.map(\.bundleID) }) }

    func action(for pkg: String, installed: (String) -> Bool) -> ClickAction? {
        guard let entry = byPkg[pkg] else { return nil }
        if let app = entry.mac.first(where: { installed($0.bundleID) }) {
            return .launchApp(bundleID: app.bundleID, name: app.name)
        }
        return entry.web.map { .openLink($0) }
    }

    // Entry by entry, so a malformed or repeated entry drops only itself. Nil when the whole is
    // unreadable.
    static func decode(from data: Data) -> (library: ClickLibrary, dropped: Int)? {
        guard let file = try? JSONDecoder().decode(File.self, from: data) else { return nil }
        var kept: [Entry] = []
        var pkgs: Set<String> = []
        for stored in file.apps {
            guard let entry = stored.entry, pkgs.insert(entry.pkg).inserted else { continue }
            kept.append(entry)
        }
        return (ClickLibrary(entries: kept), file.apps.count - kept.count)
    }

    private struct File: Decodable {
        var apps: [Lenient]
    }

    private struct Lenient: Decodable {
        var entry: Entry?

        init(from decoder: any Decoder) throws {
            entry = (try? Stored(from: decoder)).flatMap(\.valid)
        }
    }

    private struct Stored: Decodable {
        var pkg: String
        var web: String?
        var mac: [MacApp]?

        var valid: Entry? {
            let mac = mac ?? []
            guard !pkg.isEmpty, !pkg.contains(where: \.isWhitespace) else { return nil }
            if let web, !(web.hasPrefix("https://") && ClickLink.normalized(web) == web) { return nil }
            guard mac.allSatisfy({ !$0.bundleID.isEmpty && !$0.bundleID.contains(where: \.isWhitespace) && !$0.name.isEmpty }),
                  Set(mac.map(\.bundleID)).count == mac.count,
                  web != nil || !mac.isEmpty
            else { return nil }
            return Entry(pkg: pkg, web: web, mac: mac)
        }
    }
}
