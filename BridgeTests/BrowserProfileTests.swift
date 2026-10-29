import Foundation
import Testing

private let chrome = ChromiumBrowser.named("com.google.Chrome")!

@Suite("Browser profiles")
struct BrowserProfileTests {
    @Test("the profiles are the folders Chromium names, never its system or guest one")
    func directories() {
        #expect(ChromiumBrowser.profileDirectories.first == "Default")
        #expect(ChromiumBrowser.profileDirectories.contains("Profile 1"))
        #expect(ChromiumBrowser.profileDirectories.contains("Profile 100"))
        #expect(!ChromiumBrowser.profileDirectories.contains("Profile 0"))
        #expect(!ChromiumBrowser.profileDirectories.contains("System Profile"))
        #expect(!ChromiumBrowser.profileDirectories.contains("Guest Profile"))
        #expect(Set(ChromiumBrowser.profileDirectories).count == ChromiumBrowser.profileDirectories.count)
    }

    @Test("a profile sticks to a web link only")
    func webOnly() {
        let profile = BrowserProfile(bundleID: "com.google.Chrome", directory: "Profile 1")
        #expect(ClickAction.link("https://example.com", in: profile) == .openLink("https://example.com", in: profile))
        #expect(ClickAction.link("HTTP://example.com", in: profile) == .openLink("HTTP://example.com", in: profile))
        #expect(ClickAction.link("slack://open", in: profile) == .openLink("slack://open"))
        #expect(ClickAction.link("mailto:someone@example.com", in: profile) == .openLink("mailto:someone@example.com"))
        #expect(ClickAction.link("https://example.com", in: nil) == .openLink("https://example.com"))
    }

    @Test("every known browser is listed once")
    func known() {
        #expect(Set(ChromiumBrowser.known.map(\.bundleID)).count == ChromiumBrowser.known.count)
        #expect(ChromiumBrowser.named("com.apple.Safari") == nil)
        #expect(chrome.dataPath == "Google/Chrome")
    }
}
