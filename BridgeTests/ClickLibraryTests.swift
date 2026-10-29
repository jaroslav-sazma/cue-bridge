import Foundation
import Testing

private let chat = "com.example.chat"
private let mail = "com.example.mail"
private let notes = "com.example.notes"
private let unknown = "com.example.unknown"

private let library = ClickLibrary(entries: [
    .init(pkg: chat, web: "https://chat.example.com", mac: [
        .init(bundleID: "com.example.ChatMac", name: "Chat"),
        .init(bundleID: "com.example.ChatLite", name: "Chat Lite"),
    ]),
    .init(pkg: mail, web: "https://mail.example.com"),
    .init(pkg: notes, mac: [.init(bundleID: "com.example.Notes", name: "Notes")]),
])

private func installed(_ bundleIDs: String...) -> (String) -> Bool {
    { bundleIDs.contains($0) }
}

private let bundled = Vectors.repoRoot.appending(path: "Bridge/ClickLibrary.json")

@Suite("Click library")
struct ClickLibraryTests {
    @Test("the bundled library reads whole and keeps its rules")
    func bundledFile() throws {
        let data = try Data(contentsOf: bundled)
        let decoded = try #require(ClickLibrary.decode(from: data))
        #expect(decoded.dropped == 0)
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let apps = try #require(raw["apps"] as? [[String: Any]])
        #expect(decoded.library.entries.count == apps.count)
        let pkgs = decoded.library.entries.map(\.pkg)
        #expect(!pkgs.isEmpty)
        #expect(Set(pkgs).count == pkgs.count, "every package is listed once")
        #expect(pkgs == pkgs.sorted(), "entries are sorted by package")
        for entry in decoded.library.entries {
            #expect(!entry.pkg.isEmpty)
            #expect(entry.web != nil || !entry.mac.isEmpty, "\(entry.pkg) has a link or a Mac app")
            if let web = entry.web {
                let host = URLComponents(string: web)?.host ?? ""
                #expect(web.hasPrefix("https://") && !host.isEmpty, "\(entry.pkg): \(web) is https with a host")
                #expect(ClickLink.normalized(web) == web, "\(entry.pkg): \(web) is normalized")
            }
            let bundleIDs = entry.mac.map(\.bundleID)
            #expect(bundleIDs.allSatisfy { !$0.isEmpty && !$0.contains(where: \.isWhitespace) }, "\(entry.pkg) has no blank bundle ID")
            #expect(Set(bundleIDs).count == bundleIDs.count, "\(entry.pkg) lists a Mac app once")
            #expect(entry.mac.allSatisfy { !$0.name.isEmpty }, "\(entry.pkg) names its Mac apps")
        }
    }

    @Test("a malformed or repeated entry drops only itself")
    func lenient() throws {
        let data = Data(#"""
            {"apps": [
              {"pkg": "a", "web": "https://a.example.com"},
              {"pkg": "b"},
              {"pkg": "c", "web": "http://c.example.com"},
              {"pkg": "d", "web": "slack://open"},
              {"pkg": "e", "web": "e.example.com"},
              {"pkg": "", "web": "https://empty.example.com"},
              {"pkg": "f", "mac": [{"bundleID": "", "name": "F"}]},
              {"pkg": "g", "mac": [{"bundleID": "com.example.G", "name": "G"}, {"bundleID": "com.example.G", "name": "G2"}]},
              {"pkg": "h", "mac": []},
              {"pkg": "i", "mac": [{"bundleID": "com.example.I"}]},
              {"web": "https://nopkg.example.com"},
              {"pkg": "k l", "web": "https://k.example.com"},
              {"pkg": "m", "mac": [{"bundleID": "com.example. M", "name": "M"}]},
              {"pkg": "a", "web": "https://other.example.com"},
              {"pkg": "j", "mac": [{"bundleID": "com.example.J", "name": "J"}]}
            ]}
            """#.utf8)
        let decoded = try #require(ClickLibrary.decode(from: data))
        #expect(decoded.library == ClickLibrary(entries: [
            .init(pkg: "a", web: "https://a.example.com"),
            .init(pkg: "j", mac: [.init(bundleID: "com.example.J", name: "J")]),
        ]))
        #expect(decoded.dropped == 13)
    }

    @Test("an unreadable file reads as nothing")
    func unreadable() {
        #expect(ClickLibrary.decode(from: Data("garbage".utf8)) == nil)
        #expect(ClickLibrary.decode(from: Data("{}".utf8)) == nil)
        #expect(ClickLibrary.decode(from: Data(#"{"apps": {}}"#.utf8)) == nil)
        #expect(ClickLibrary.decode(from: Data(#"{"apps": []}"#.utf8))?.library == ClickLibrary())
    }

    @Test("the first installed Mac app wins, then the web link, and nothing for an app not listed")
    func libraryAction() {
        #expect(library.action(for: chat, installed: installed("com.example.ChatMac", "com.example.ChatLite"))
            == .launchApp(bundleID: "com.example.ChatMac", name: "Chat"))
        #expect(library.action(for: chat, installed: installed("com.example.ChatLite"))
            == .launchApp(bundleID: "com.example.ChatLite", name: "Chat Lite"))
        #expect(library.action(for: chat, installed: installed()) == .openLink("https://chat.example.com", in: nil))
        #expect(library.action(for: mail, installed: installed("com.example.ChatMac")) == .openLink("https://mail.example.com"))
        #expect(library.action(for: notes, installed: installed("com.example.Notes"))
            == .launchApp(bundleID: "com.example.Notes", name: "Notes"))
        #expect(library.action(for: notes, installed: installed()) == nil)
        #expect(library.action(for: unknown, installed: { _ in true }) == nil)
        #expect(library.bundleIDs == ["com.example.ChatMac", "com.example.ChatLite", "com.example.Notes"])
    }

    @Test("the app's own action, then the library, then all other apps, then the reminder")
    func order() {
        let own = ClickAction.openLink("https://own.example.com")
        let others = ClickAction.openLink("https://others.example.com")
        let none = installed()
        let chatMac = installed("com.example.ChatMac")

        #expect(ClickRoutes(perApp: [chat: own], fallback: others).resolve(chat, library: library, installed: chatMac) == own)
        #expect(ClickRoutes(fallback: others).resolve(chat, library: library, installed: chatMac)
            == .launchApp(bundleID: "com.example.ChatMac", name: "Chat"))
        #expect(ClickRoutes(fallback: others).resolve(chat, library: library, installed: none) == .openLink("https://chat.example.com"))
        #expect(ClickRoutes(fallback: others).resolve(notes, library: library, installed: none) == others)
        #expect(ClickRoutes(fallback: others).resolve(unknown, library: library, installed: none) == others)
        #expect(ClickRoutes().resolve(unknown, library: library, installed: none) == nil)
        #expect(ClickRoutes().resolve(notes, library: library, installed: none) == nil)
    }

    @Test("an explicit reminder stops the library and all other apps")
    func explicitReminder() {
        let routes = ClickRoutes(perApp: [chat: .showReminder, unknown: .showReminder], fallback: .openLink("https://others.example.com"))
        #expect(routes.resolve(chat, library: library, installed: { _ in true }) == nil)
        #expect(routes.resolve(unknown, library: library, installed: { _ in true }) == nil)
        #expect(routes.resolve(mail, library: library, installed: { _ in true }) == .openLink("https://mail.example.com"))
        #expect(ClickRoutes(fallback: .showReminder).resolve(unknown, library: library, installed: { _ in true }) == nil)
    }

    @Test("the default an app's row describes is the one its click takes")
    func byDefault() {
        let others = ClickAction.launchApp(bundleID: "com.example.Other", name: "Other")
        let routes = ClickRoutes(perApp: [mail: .openLink("https://own.example.com")], fallback: others)
        #expect(routes.byDefault(chat, library: library, installed: installed("com.example.ChatLite"))
            == .library(.launchApp(bundleID: "com.example.ChatLite", name: "Chat Lite")))
        #expect(routes.byDefault(mail, library: library, installed: installed()) == .library(.openLink("https://mail.example.com")))
        #expect(routes.byDefault(notes, library: library, installed: installed()) == .fallback(others))
        #expect(ClickRoutes().byDefault(notes, library: library, installed: installed()) == .reminder)
        #expect(ClickRoutes(fallback: .showReminder).byDefault(unknown, library: library, installed: installed()) == .reminder)
        for pkg in [chat, notes, unknown] {
            for check in [installed(), installed("com.example.ChatMac"), installed("com.example.Notes")] {
                let shown: ClickAction? = switch routes.byDefault(pkg, library: library, installed: check) {
                case .library(let action), .fallback(let action): action
                case .reminder: nil
                }
                #expect(routes.resolve(pkg, library: library, installed: check) == shown)
            }
        }
    }

    @Test("a default with a profile opens the library's web link there and a Mac app as it is")
    func defaultWithProfile() {
        let profile = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")
        let others = ClickAction.openLink("https://others.example.com")
        let routes = ClickRoutes(
            perApp: [chat: .libraryDefault(in: profile), mail: .libraryDefault(in: profile), notes: .libraryDefault(in: profile),
                     unknown: .libraryDefault(in: profile)],
            fallback: others
        )
        #expect(routes.resolve(mail, library: library, installed: installed()) == .openLink("https://mail.example.com", in: profile))
        #expect(routes.resolve(chat, library: library, installed: installed()) == .openLink("https://chat.example.com", in: profile))
        #expect(routes.resolve(chat, library: library, installed: installed("com.example.ChatMac"))
            == .launchApp(bundleID: "com.example.ChatMac", name: "Chat"))
        #expect(routes.resolve(notes, library: library, installed: installed()) == others)
        #expect(routes.resolve(unknown, library: library, installed: installed()) == others)
        #expect(ClickRoutes(perApp: [unknown: .libraryDefault(in: profile)]).resolve(unknown, library: library, installed: installed()) == nil)
        #expect(routes.configured.contains(chat))
    }

    @Test("a profile stored for all other apps counts as no action for them")
    func profileAsFallback() {
        let profile = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")
        let routes = ClickRoutes(fallback: .libraryDefault(in: profile))
        #expect(routes.byDefault(unknown, library: library, installed: installed()) == .reminder)
        #expect(routes.resolve(unknown, library: library, installed: installed()) == nil)
        #expect(routes.resolve(mail, library: library, installed: installed()) == .openLink("https://mail.example.com"))
    }

    @Test("the profile picker shows under Default exactly when the click opens a library web link")
    func profilePicker() {
        let profile = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")
        let others = ClickAction.openLink("https://others.example.com")
        let routeSets = [
            ClickRoutes(fallback: others),
            ClickRoutes(),
            ClickRoutes(perApp: [chat: .libraryDefault(in: profile), mail: .libraryDefault(in: profile),
                                 notes: .libraryDefault(in: profile), unknown: .libraryDefault(in: profile)], fallback: others),
        ]
        let cases: [(pkg: String, installed: [String], takesProfile: Bool)] = [
            (chat, [], true),
            (chat, ["com.example.Notes"], true),
            (chat, ["com.example.ChatMac"], false),
            (mail, [], true),
            (mail, ["com.example.ChatMac"], true),
            (notes, [], false),
            (notes, ["com.example.Notes"], false),
            (unknown, [], false),
            (unknown, ["com.example.ChatMac"], false),
        ]
        for routes in routeSets {
            for (pkg, bundleIDs, takesProfile) in cases {
                let check: (String) -> Bool = { bundleIDs.contains($0) }
                let byDefault = routes.byDefault(pkg, library: library, installed: check)
                let shown: ClickAction? = switch byDefault {
                case .library(let action), .fallback(let action): action
                case .reminder: nil
                }
                let resolved = routes.resolve(pkg, library: library, installed: check)
                #expect(resolved == shown, "\(pkg) with \(bundleIDs)")
                #expect(byDefault.takesBrowserProfile == takesProfile, "\(pkg) with \(bundleIDs)")
            }
        }
        #expect(DefaultClick.fallback(others).takesBrowserProfile == false)
        #expect(DefaultClick.library(.launchApp(bundleID: "com.example.ChatMac", name: "Chat")).takesBrowserProfile == false)
        #expect(DefaultClick.library(.openLink("https://mail.example.com", in: profile)).takesBrowserProfile)
        #expect(DefaultClick.library(.openLink("slack://open")).takesBrowserProfile == false)
        #expect(DefaultClick.reminder.takesBrowserProfile == false)
    }

    @Test("a web link without a profile of its own opens in the default browser's profile")
    func defaultBrowser() {
        let global = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")
        let own = BrowserProfile(bundleID: "com.brave.Browser", directory: "Default")
        let chatMac = ClickAction.launchApp(bundleID: "com.example.ChatMac", name: "Chat")
        let routes = ClickRoutes(
            perApp: [
                chat: .openLink("https://own.example.com"),
                mail: .openLink("slack://open"),
                notes: .launchApp(bundleID: "com.example.Notes", name: "Notes"),
                "com.example.profiled": .openLink("https://profiled.example.com", in: own),
            ],
            fallback: .openLink("https://others.example.com")
        )
        var withGlobal = routes
        withGlobal.defaultBrowser = global
        func resolve(_ routes: ClickRoutes, _ pkg: String, _ installed: (String) -> Bool = installed()) -> ClickAction? {
            routes.resolve(pkg, library: library, installed: installed)
        }

        #expect(resolve(routes, chat) == .openLink("https://own.example.com"))
        #expect(resolve(withGlobal, chat) == .openLink("https://own.example.com", in: global))
        #expect(resolve(withGlobal, mail) == .openLink("slack://open"))
        #expect(resolve(withGlobal, notes) == .launchApp(bundleID: "com.example.Notes", name: "Notes"))
        #expect(resolve(withGlobal, "com.example.profiled") == .openLink("https://profiled.example.com", in: own))
        #expect(resolve(routes, unknown) == .openLink("https://others.example.com"))
        #expect(resolve(withGlobal, unknown) == .openLink("https://others.example.com", in: global))

        var fallbackOther = withGlobal
        fallbackOther.fallback = .openLink("mailto:someone@example.com")
        #expect(resolve(fallbackOther, unknown) == .openLink("mailto:someone@example.com"))
        fallbackOther.fallback = .openLink("https://others.example.com", in: own)
        #expect(resolve(fallbackOther, unknown) == .openLink("https://others.example.com", in: own))
        fallbackOther.fallback = chatMac
        #expect(resolve(fallbackOther, unknown) == chatMac)
    }

    @Test("a library default opens its web link in the default browser's profile unless its own is set")
    func libraryDefaultInDefaultBrowser() {
        let global = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")
        let own = BrowserProfile(bundleID: "com.brave.Browser", directory: "Default")
        let routes = ClickRoutes(perApp: [chat: .libraryDefault(in: own)], defaultBrowser: global)
        #expect(routes.resolve(mail, library: library, installed: installed()) == .openLink("https://mail.example.com", in: global))
        #expect(routes.byDefault(mail, library: library, installed: installed())
            == .library(.openLink("https://mail.example.com", in: global)))
        #expect(routes.resolve(chat, library: library, installed: installed()) == .openLink("https://chat.example.com", in: own))
        #expect(routes.resolve(chat, library: library, installed: installed("com.example.ChatMac"))
            == .launchApp(bundleID: "com.example.ChatMac", name: "Chat"))
        #expect(routes.resolve(notes, library: library, installed: installed("com.example.Notes"))
            == .launchApp(bundleID: "com.example.Notes", name: "Notes"))
        #expect(routes.resolve(notes, library: library, installed: installed()) == nil)
        #expect(routes.byDefault(mail, library: library, installed: installed()).takesBrowserProfile)

        let withFallback = ClickRoutes(fallback: .openLink("https://others.example.com"), defaultBrowser: global)
        #expect(withFallback.byDefault(notes, library: library, installed: installed())
            == .fallback(.openLink("https://others.example.com", in: global)))
        #expect(withFallback.resolve(notes, library: library, installed: installed()) == .openLink("https://others.example.com", in: global))
    }

    @Test("a default whose library entry is gone falls to all other apps, in the default browser's profile")
    func libraryDefaultGone() {
        let global = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")
        let own = BrowserProfile(bundleID: "com.brave.Browser", directory: "Default")
        let others = "https://others.example.com"
        let routes = ClickRoutes(perApp: [unknown: .libraryDefault(in: own)], fallback: .openLink(others), defaultBrowser: global)
        #expect(routes.byDefault(unknown, library: library, installed: installed()) == .fallback(.openLink(others, in: global)))
        #expect(routes.resolve(unknown, library: library, installed: installed()) == .openLink(others, in: global))
        #expect(routes.resolve(unknown, library: ClickLibrary(), installed: installed()) == .openLink(others, in: global))
        #expect(routes.byDefault(unknown, library: library, installed: installed()).takesBrowserProfile == false)
    }

    @Test("a library without the app behaves as no library at all")
    func unlisted() {
        let others = ClickAction.openLink("https://others.example.com")
        for routes in [ClickRoutes(), ClickRoutes(fallback: others), ClickRoutes(perApp: [unknown: others])] {
            #expect(routes.resolve(unknown, library: library, installed: { _ in true })
                == routes.resolve(unknown, library: ClickLibrary(), installed: { _ in true }))
        }
    }
}
