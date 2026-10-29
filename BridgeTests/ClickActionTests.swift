import Foundation
import Testing

private let chat = "com.example.chat"
private let mail = "com.example.mail"

private func app(_ pkg: String, _ label: String, icon: String? = nil) -> PhoneApp {
    PhoneApp(pkg: pkg, label: label, iconHash: icon)
}

private let personal = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")

private func at(_ seconds: Double) -> Date {
    Date(timeIntervalSince1970: 1_791_820_800 + seconds)
}

@Suite("Click actions")
struct ClickActionTests {
    @Test("actions, routes and seen apps survive storage unchanged")
    func roundTrip() throws {
        let routes = ClickRoutes(
            perApp: [
                chat: .launchApp(bundleID: "com.example.ChatMac", name: "Chat"),
                mail: .openLink("https://mail.example.com/inbox"),
                "com.example.news": .openLink("https://news.example.com", in: personal),
                "com.example.web": .libraryDefault(in: personal),
            ],
            fallback: .openLink("slack://open")
        )
        let stored = try #require(ClickStorage.encode(routes))
        #expect(ClickStorage.decode(ClickRoutes.self, from: stored) == routes)
        #expect(ClickStorage.decode(ClickRoutes.self, from: ClickStorage.encode(ClickRoutes())) == ClickRoutes())

        var seen = SeenApps()
        seen.record(app(chat, "Chat", icon: String(repeating: "a", count: 64)), at: at(1), keeping: [])
        seen.record(app(mail, "Mail"), at: at(2), keeping: [])
        let decoded = ClickStorage.decode(SeenApps.self, from: ClickStorage.encode(seen))
        #expect(decoded == seen)
    }

    @Test("an action is stored with an explicit kind")
    func storedForm() throws {
        let link = try #require(ClickStorage.encode(ClickAction.openLink("https://example.com")))
        #expect(String(decoding: link, as: UTF8.self) == #"{"kind":"link","url":"https:\/\/example.com"}"#)
        let app = try #require(ClickStorage.encode(ClickAction.launchApp(bundleID: "com.example.Mac", name: "Mac")))
        #expect(String(decoding: app, as: UTF8.self) == #"{"bundleID":"com.example.Mac","kind":"app","name":"Mac"}"#)
        let profiled = try #require(ClickStorage.encode(ClickAction.openLink("https://example.com", in: personal)))
        #expect(String(decoding: profiled, as: UTF8.self) == #"{"browser":{"bundleID":"com.google.Chrome","directory":"Profile 1"},"kind":"profileLink","url":"https:\/\/example.com"}"#)
    }

    @Test("a link stored before browser profiles opens in the default browser")
    func linkWithoutProfile() throws {
        let stored = Data(#"{"perApp":{"a":{"kind":"link","url":"https://example.com"}}}"#.utf8)
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        #expect(decoded.routes.perApp["a"] == .openLink("https://example.com", in: nil))
        #expect(ClickAction.openLink("https://example.com") != .openLink("https://example.com", in: personal))
    }

    @Test("a profile link without a whole profile drops itself rather than open elsewhere")
    func incompleteProfile() throws {
        let stored = Data(#"""
            {"perApp":{"a":{"kind":"profileLink","url":"https://example.com","browser":{"bundleID":"com.google.Chrome"}},
                       "b":{"kind":"profileLink","url":"https://example.com","browser":{"bundleID":"com.google.Chrome","directory":"Default"}},
                       "c":{"kind":"profileLink","url":"https://example.com","browser":null},
                       "d":{"kind":"profileLink","url":"https://example.com"}}}
            """#.utf8)
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        let me = BrowserProfile(bundleID: "com.google.Chrome", directory: "Default")
        #expect(decoded.routes == ClickRoutes(perApp: ["b": .openLink("https://example.com", in: me)]))
        #expect(decoded.dropped == 3)
    }

    @Test("a build that predates profiles sees a link with one as a kind it cannot read")
    func profileLinkKind() throws {
        let stored = try #require(ClickStorage.encode(ClickRoutes(perApp: [chat: .openLink("https://example.com", in: personal)])))
        let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let action = try #require((object["perApp"] as? [String: Any])?[chat] as? [String: Any])
        #expect(action["kind"] as? String == "profileLink")
        #expect(ClickAction.Kind(rawValue: "profileLink") == nil)
        #expect(ClickAction.openLink("https://example.com", in: personal).kind == .link)
    }

    @Test("the library's default with a profile is stored as a kind of its own, browser and all")
    func defaultLinkStored() throws {
        let stored = try #require(ClickStorage.encode(ClickAction.libraryDefault(in: personal)))
        #expect(String(decoding: stored, as: UTF8.self) == #"{"browser":{"bundleID":"com.google.Chrome","directory":"Profile 1"},"kind":"defaultLink"}"#)
        #expect(ClickStorage.decode(ClickAction.self, from: stored) == .libraryDefault(in: personal))
        #expect(ClickAction.libraryDefault(in: personal).kind == .defaultLink)
    }

    @Test("a default link without a whole profile drops itself, and an unknown kind leaves Default")
    func incompleteDefaultLink() throws {
        let stored = Data(#"""
            {"perApp":{"a":{"kind":"defaultLink","browser":{"bundleID":"com.google.Chrome"}},
                       "b":{"kind":"defaultLink","browser":{"bundleID":"com.google.Chrome","directory":"Default"}},
                       "c":{"kind":"defaultLink"},
                       "d":{"kind":"defaultLinkV2","browser":{"bundleID":"com.google.Chrome","directory":"Default"}}}}
            """#.utf8)
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        let me = BrowserProfile(bundleID: "com.google.Chrome", directory: "Default")
        #expect(decoded.routes == ClickRoutes(perApp: ["b": .libraryDefault(in: me)]))
        #expect(decoded.dropped == 3)
    }

    @Test("unreadable or missing data reads as nothing stored")
    func unreadable() {
        #expect(ClickStorage.decode(ClickRoutes.self, from: nil) == nil)
        #expect(ClickStorage.decode(ClickRoutes.self, from: Data("garbage".utf8)) == nil)
        #expect(ClickStorage.decodeRoutes(from: nil) == nil)
        #expect(ClickStorage.decodeRoutes(from: Data("garbage".utf8)) == nil)
        #expect(ClickStorage.decodeRoutes(from: Data(#"{"perApp":[]}"#.utf8)) == nil)
    }

    @Test("an action this build cannot read drops only itself")
    func unreadableEntry() throws {
        let stored = Data(#"""
            {"perApp":{"a":{"kind":"shortcut"},"b":{"kind":"link","url":"https://example.com"},"c":{"kind":"app"}},
             "fallback":{"kind":"shortcut"}}
            """#.utf8)
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        #expect(decoded.routes == ClickRoutes(perApp: ["b": .openLink("https://example.com")]))
        #expect(decoded.dropped == 3)
        let routes = ClickRoutes(perApp: [chat: .openLink("https://example.com")], fallback: .openLink("slack://open"))
        let clean = try #require(ClickStorage.decodeRoutes(from: ClickStorage.encode(routes)))
        #expect(clean.routes == routes)
        #expect(clean.dropped == 0)
        #expect(ClickStorage.decodeRoutes(from: Data("{}".utf8))?.routes == ClickRoutes())
    }

    @Test("the app's own action beats the one for all other apps, which beats the reminder")
    func resolution() {
        let own = ClickAction.launchApp(bundleID: "com.example.ChatMac", name: "Chat")
        let others = ClickAction.openLink("https://example.com")
        func resolve(_ routes: ClickRoutes, _ pkg: String) -> ClickAction? {
            routes.resolve(pkg, library: ClickLibrary(), installed: { _ in true })
        }
        #expect(resolve(ClickRoutes(), chat) == nil)
        #expect(resolve(ClickRoutes(perApp: [chat: own]), chat) == own)
        #expect(resolve(ClickRoutes(perApp: [chat: own]), mail) == nil)
        #expect(resolve(ClickRoutes(perApp: [chat: own], fallback: others), chat) == own)
        #expect(resolve(ClickRoutes(perApp: [chat: own], fallback: others), mail) == others)
        #expect(resolve(ClickRoutes(fallback: others), chat) == others)
    }

    @Test("an explicit reminder is stored with a kind of its own and survives storage")
    func reminderStored() throws {
        let stored = try #require(ClickStorage.encode(ClickAction.showReminder))
        #expect(String(decoding: stored, as: UTF8.self) == #"{"kind":"reminder"}"#)
        #expect(ClickStorage.decode(ClickAction.self, from: stored) == .showReminder)
        #expect(ClickAction.showReminder.kind == .reminder)
        let routes = ClickRoutes(perApp: [chat: .showReminder, mail: .openLink("https://mail.example.com")])
        let decoded = try #require(ClickStorage.decodeRoutes(from: ClickStorage.encode(routes)))
        #expect(decoded.routes == routes)
        #expect(decoded.dropped == 0)
    }

    @Test("routes stored before the explicit reminder still read")
    func olderRoutes() throws {
        let stored = Data(#"""
            {"perApp":{"a":{"kind":"app","bundleID":"com.example.Mac","name":"Mac"},"b":{"kind":"link","url":"https://example.com"}},
             "fallback":{"kind":"link","url":"slack://open"}}
            """#.utf8)
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        #expect(decoded.routes == ClickRoutes(
            perApp: ["a": .launchApp(bundleID: "com.example.Mac", name: "Mac"), "b": .openLink("https://example.com")],
            fallback: .openLink("slack://open")
        ))
        #expect(decoded.dropped == 0)
    }

    @Test("the default browser survives storage, and routes stored without one still read")
    func defaultBrowserStored() throws {
        let routes = ClickRoutes(perApp: [chat: .openLink("https://example.com")], defaultBrowser: personal)
        let stored = try #require(ClickStorage.encode(routes))
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        #expect(decoded.routes == routes)
        #expect(decoded.dropped == 0)
        #expect(ClickStorage.decode(ClickRoutes.self, from: stored) == routes)
        let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(object["defaultBrowser"] as? [String: String] == ["bundleID": "com.google.Chrome", "directory": "Profile 1"])

        let none = try #require(ClickStorage.encode(ClickRoutes(perApp: [chat: .showReminder])))
        #expect(String(decoding: none, as: UTF8.self) == #"{"perApp":{"com.example.chat":{"kind":"reminder"}}}"#)

        let older = Data(#"{"perApp":{"a":{"kind":"link","url":"https://example.com"}},"fallback":{"kind":"link","url":"slack://open"}}"#.utf8)
        let olderDecoded = try #require(ClickStorage.decodeRoutes(from: older))
        #expect(olderDecoded.routes == ClickRoutes(perApp: ["a": .openLink("https://example.com")], fallback: .openLink("slack://open")))
        #expect(olderDecoded.routes.defaultBrowser == nil)
        #expect(ClickStorage.decode(ClickRoutes.self, from: older)?.defaultBrowser == nil)
    }

    @Test("a default browser without a whole profile drops only itself")
    func incompleteDefaultBrowser() throws {
        let stored = Data(#"""
            {"perApp":{"a":{"kind":"link","url":"https://example.com"}},"defaultBrowser":{"bundleID":"com.google.Chrome"}}
            """#.utf8)
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        #expect(decoded.routes == ClickRoutes(perApp: ["a": .openLink("https://example.com")]))
        #expect(decoded.dropped == 1)
        let null = try #require(ClickStorage.decodeRoutes(from: Data(#"{"defaultBrowser":null}"#.utf8)))
        #expect(null.routes == ClickRoutes())
        #expect(null.dropped == 0)
    }

    @Test("an unknown kind and a broken default browser each drop only themselves")
    func unknownKindAndBrokenDefaultBrowser() throws {
        let stored = Data(#"""
            {"perApp":{"a":{"kind":"link","url":"https://example.com"},"b":{"kind":"shortcut"}},
             "fallback":{"kind":"link","url":"slack://open"},"defaultBrowser":{"directory":"Profile 1"}}
            """#.utf8)
        let decoded = try #require(ClickStorage.decodeRoutes(from: stored))
        #expect(decoded.routes == ClickRoutes(perApp: ["a": .openLink("https://example.com")], fallback: .openLink("slack://open")))
        #expect(decoded.routes.defaultBrowser == nil)
        #expect(decoded.dropped == 2)
    }

    @Test("the reminder's userInfo carries the app, and a foreign one carries none")
    func reminderUserInfo() throws {
        for phoneApp in [app(chat, "Chat", icon: String(repeating: "b", count: 64)), app(mail, "Mail")] {
            let bridged = try #require((phoneApp.userInfo as NSDictionary) as? [AnyHashable: Any])
            #expect(PhoneApp(userInfo: bridged) == phoneApp)
        }
        #expect(PhoneApp(userInfo: [:]) == nil)
        #expect(PhoneApp(userInfo: [PhoneApp.marker: 1, "pkg": "", "appLabel": "X"]) == nil)
        #expect(PhoneApp(userInfo: ["pkg": chat, "appLabel": "Chat"]) == nil)
    }
}

@Suite("Click links")
struct ClickLinkTests {
    @Test("a web address without a scheme becomes https, trimmed")
    func addsScheme() {
        #expect(ClickLink.normalized("example.com") == "https://example.com")
        #expect(ClickLink.normalized("  messages.example.com/web?x=1 \n") == "https://messages.example.com/web?x=1")
        #expect(ClickLink.normalized("example.com:8080/path") == "https://example.com:8080/path")
        #expect(ClickLink.normalized("localhost:8080") == "https://localhost:8080")
        #expect(ClickLink.normalized("LocalHost:8080/x") == "https://LocalHost:8080/x")
    }

    @Test("a scheme without a dot stays a scheme, digits after its colon or not")
    func schemeBeforeDigits() {
        #expect(ClickLink.normalized("tel:5551234") == "tel:5551234")
        #expect(ClickLink.normalized("tel:123") == "tel:123")
        #expect(ClickLink.normalized("sms:5551234") == "sms:5551234")
    }

    @Test("a link with a scheme is kept as typed")
    func keepsScheme() {
        #expect(ClickLink.normalized("https://example.com/a") == "https://example.com/a")
        #expect(ClickLink.normalized("http://example.com") == "http://example.com")
        #expect(ClickLink.normalized("HTTPS://Example.com") == "HTTPS://Example.com")
        #expect(ClickLink.normalized("slack://open") == "slack://open")
        #expect(ClickLink.normalized("mailto:someone@example.com") == "mailto:someone@example.com")
        #expect(ClickLink.normalized("com.example.app://inbox") == "com.example.app://inbox")
    }

    @Test("only http and https links are web links")
    func web() {
        #expect(ClickLink.isWeb("https://example.com"))
        #expect(ClickLink.isWeb("HTTP://example.com/a"))
        for link in ["slack://open", "mailto:someone@example.com", "tel:5551234", "example.com", ""] {
            #expect(!ClickLink.isWeb(link), "\"\(link)\" is not a web link")
        }
    }

    @Test("nothing to open is rejected")
    func rejects() {
        for raw in [
            "", "   ", "https://", "http://", "https:example.com", "exa mple.com", "https://exa mple.com",
            "mailto:", "slack:", "example.com:99999", "https://example.com:65536",
        ] {
            #expect(ClickLink.normalized(raw) == nil, "\"\(raw)\" is not a link")
        }
    }
}

@Suite("Seen apps")
struct SeenAppsTests {
    @Test("a sighting adds the app, a later one updates its label and keeps a known icon")
    func recordAndUpdate() throws {
        let icon = String(repeating: "c", count: 64)
        var seen = SeenApps()
        seen.record(app(chat, "Chat", icon: icon), at: at(1), keeping: [])
        seen.record(app(chat, "Chat Pro"), at: at(5), keeping: [])
        let sighting = try #require(seen.sightings[chat])
        #expect(sighting.app == app(chat, "Chat Pro", icon: icon))
        #expect(sighting.lastSeen == at(5))
        #expect(seen.sightings.count == 1)
        let other = String(repeating: "d", count: 64)
        seen.record(app(chat, "Chat Pro", icon: other), at: at(6), keeping: [])
        #expect(seen.sightings[chat]?.app.iconHash == other)
    }

    @Test("an app without a package is not recorded")
    func emptyPackage() {
        var seen = SeenApps()
        seen.record(app("", "Nothing"), at: at(1), keeping: [])
        #expect(seen.sightings.count == 0)
    }

    @Test("past the cap the oldest sighting goes first")
    func prunesOldest() {
        var seen = SeenApps()
        for index in 0..<SeenApps.cap {
            seen.record(app("app.\(index)", "App \(index)"), at: at(Double(index)), keeping: [])
        }
        seen.record(app("app.0", "App 0"), at: at(100), keeping: [])
        seen.record(app("app.new", "New"), at: at(101), keeping: [])
        #expect(seen.sightings.count == SeenApps.cap)
        #expect(seen.sightings["app.0"] != nil)
        #expect(seen.sightings["app.1"] == nil)
        #expect(seen.sightings["app.new"] != nil)
    }

    @Test("an app with an action of its own is never pruned")
    func keepsConfigured() {
        var seen = SeenApps()
        for index in 0..<SeenApps.cap {
            seen.record(app("app.\(index)", "App \(index)"), at: at(Double(index)), keeping: [])
        }
        seen.record(app("app.new", "New"), at: at(100), keeping: ["app.0", "app.1"])
        #expect(seen.sightings.count == SeenApps.cap)
        #expect(seen.sightings["app.0"] != nil)
        #expect(seen.sightings["app.1"] != nil)
        #expect(seen.sightings["app.2"] == nil)
    }

    @Test("an app set to Show Reminder counts as configured and is never pruned")
    func keepsExplicitReminder() {
        var seen = SeenApps()
        for index in 0..<SeenApps.cap {
            seen.record(app("app.\(index)", "App \(index)"), at: at(Double(index)), keeping: [])
        }
        let configured = ClickRoutes(perApp: ["app.0": .showReminder]).configured
        #expect(configured == ["app.0"])
        seen.record(app("app.new", "New"), at: at(100), keeping: configured)
        #expect(seen.sightings.count == SeenApps.cap)
        #expect(seen.sightings["app.0"] != nil)
        #expect(seen.sightings["app.1"] == nil)
    }

    @Test("with every older app configured the list grows past the cap rather than drop one")
    func allConfigured() {
        var seen = SeenApps()
        var configured: Set<String> = []
        for index in 0..<SeenApps.cap {
            seen.record(app("app.\(index)", "App \(index)"), at: at(Double(index)), keeping: [])
            configured.insert("app.\(index)")
        }
        seen.record(app("app.new", "New"), at: at(100), keeping: configured)
        #expect(seen.sightings.count == SeenApps.cap + 1)
        #expect(seen.sightings["app.new"] != nil)
    }

    @Test("the settings order is by the name shown, ignoring case, then by package")
    func ordering() {
        var seen = SeenApps()
        seen.record(app("com.z", "beta"), at: at(1), keeping: [])
        seen.record(app("com.b", "Alpha"), at: at(2), keeping: [])
        seen.record(app("com.a", "alpha"), at: at(3), keeping: [])
        seen.record(app("com.c", "Gamma"), at: at(4), keeping: [])
        seen.record(app("com.delta", ""), at: at(5), keeping: [])
        #expect(seen.ordered.map(\.app.pkg) == ["com.a", "com.b", "com.z", "com.delta", "com.c"])
        #expect(app("com.delta", "").displayName == "com.delta")
        #expect(app("com.a", "alpha").displayName == "alpha")
    }

    @Test("only a new app, a changed label or icon, or a minute's move of lastSeen is worth a write")
    func differs() {
        var seen = SeenApps()
        seen.record(app(chat, "Chat"), at: at(0), keeping: [])
        var next = seen
        next.record(app(chat, "Chat"), at: at(SeenApps.refresh - 1), keeping: [])
        #expect(!next.differs(from: seen))
        next.record(app(chat, "Chat"), at: at(SeenApps.refresh), keeping: [])
        #expect(next.differs(from: seen))
        next = seen
        next.record(app(chat, "Chat Pro"), at: at(1), keeping: [])
        #expect(next.differs(from: seen))
        next = seen
        next.record(app(chat, "Chat", icon: String(repeating: "e", count: 64)), at: at(1), keeping: [])
        #expect(next.differs(from: seen))
        next = seen
        next.record(app(mail, "Mail"), at: at(1), keeping: [])
        #expect(next.differs(from: seen))
    }
}
