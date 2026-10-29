import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClickSettingsSection: View {
    let clicks: ClickStore
    let icons: IconCache
    let browsers: [BrowserProfile]?
    let installed: Set<String>?
    let highlighted: String?
    let drafts: ClickDrafts

    var body: some View {
        Section {
            let apps = clicks.seen.ordered
            if apps.isEmpty {
                Text("Apps appear here as their notifications arrive.")
                    .foregroundStyle(.secondary)
            }
            ForEach(apps) { seen in
                let pkg = seen.app.pkg
                let byDefault = installed.map { clicks.byDefault(pkg, installed: $0.contains) }
                ClickActionRow(
                    title: seen.app.displayName, source: seen.app.displayName,
                    action: Binding(get: { clicks.routes.perApp[pkg] }, set: { clicks.set($0, for: pkg) }),
                    offersDefault: true, defaultCaption: byDefault.map(Self.caption),
                    defaultTakesBrowser: byDefault?.takesBrowserProfile == true, browsers: browsers,
                    drafts: drafts, draftKey: pkg
                ) {
                    PhoneAppIcon(hash: seen.app.iconHash, icons: icons)
                }
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.tint.quaternary)
                        .padding(-5)
                        .opacity(highlighted == seen.app.pkg ? 1 : 0)
                }
                .id(pkg)
            }
            ClickActionRow(
                title: "All Other Apps", source: "any other app",
                action: Binding(get: { clicks.routes.fallback }, set: { clicks.setFallback($0) }),
                offersDefault: false, defaultCaption: nil, defaultTakesBrowser: false, browsers: browsers,
                drafts: drafts, draftKey: nil
            ) {
                Image(systemName: "square.grid.2x2").resizable().scaledToFit().foregroundStyle(.secondary)
            }
            if showsDefaultBrowser {
                HStack {
                    Image(systemName: "globe")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                    Text("Default Browser")
                        .fixedSize()
                        .accessibilityHidden(true)
                    Spacer()
                    BrowserMenu(
                        label: Text("Default Browser"),
                        selection: Binding(get: { clicks.routes.defaultBrowser }, set: { clicks.setDefaultBrowser($0) }),
                        browsers: browsers, noneTitle: "System Default"
                    )
                }
            }
        } header: {
            Text("Notification Click")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clicking a notification here opens what you choose for its app and closes the notification on your phone. A click that shows the reminder leaves it on your phone.")
                Text("Default opens the Mac app or the website of a common app, and otherwise does what All Other Apps does.")
                if showsDefaultBrowser {
                    Text("Default Browser chooses the browser profile for every web link that has none of its own.")
                }
                if browsers?.isEmpty == false {
                    Text("Browser profiles are listed by folder. A browser shows a profile's folder at the end of Profile Path on its version page, such as chrome://version.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    // Hidden without a Chromium browser, unless a choice is stored that can still be changed back.
    private var showsDefaultBrowser: Bool {
        !BrowserMenu.options(browsers, keeping: clicks.routes.defaultBrowser).isEmpty
    }

    private static func caption(_ byDefault: DefaultClick) -> String {
        switch byDefault {
        case .library(.launchApp(_, let name)): "Opens \(name)"
        case .library(.openLink(let url, _)): "Opens \(URLComponents(string: url)?.host ?? url)"
        case .fallback: "Same as All Other Apps"
        case .library(.showReminder), .library(.libraryDefault), .reminder: "Shows a reminder"
        }
    }
}

private enum ClickKind {
    case byDefault, reminder, link, app
}

// What a row shows but has not stored — a link not valid yet, Open an App with no app chosen. The
// form rebuilds a row scrolled out of view, so it is kept here. One object per window opening: a
// row's late onDisappear writes into the object it was built with, never into the next opening's.
final class ClickDrafts {
    // Keyed by package; nil is All Other Apps.
    fileprivate private(set) var byRow: [String?: ClickDraft] = [:]

    fileprivate func keep(_ draft: ClickDraft?, for key: String?) {
        byRow[key] = draft
    }
}

private struct ClickDraft: Equatable {
    var kind: ClickKind
    var link = ""
}

extension ClickDraft {
    init(_ action: ClickAction?, offersDefault: Bool) {
        switch action {
        // On All Other Apps a stored .libraryDefault stands for no action, as the click treats it.
        case nil, .libraryDefault: self.init(kind: offersDefault ? .byDefault : .reminder)
        case .showReminder: self.init(kind: .reminder)
        case .openLink(let url, _): self.init(kind: .link, link: url)
        case .launchApp: self.init(kind: .app)
        }
    }
}

private struct PhoneAppIcon: View {
    let hash: String?
    let icons: IconCache

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .task(id: hash) {
            image = hash.flatMap(icons.png).flatMap(NSImage.init(data:))
        }
    }
}

private struct ClickActionRow<Icon: View>: View {
    let title: String
    let source: String
    // Only an app's own row offers Default, which stores nil, or .libraryDefault with a profile; there
    // Show Reminder, and a link or an app not chosen yet, store .showReminder instead, while on All
    // Other Apps they store nil.
    let offersDefault: Bool
    let defaultCaption: String?
    // Read from the settings' snapshot of installed apps; the click decides afresh.
    let defaultTakesBrowser: Bool
    let browsers: [BrowserProfile]?
    let drafts: ClickDrafts
    let draftKey: String?
    let icon: Icon

    @Binding private var action: ClickAction?
    @State private var kind: ClickKind
    @State private var link: String
    @State private var linked: String?
    @State private var browser: BrowserProfile?
    @State private var defaultBrowser: BrowserProfile?
    @State private var app: (bundleID: String, name: String)?
    @State private var choosing = false
    @FocusState private var linkFocused: Bool

    init(
        title: String, source: String, action: Binding<ClickAction?>, offersDefault: Bool, defaultCaption: String?,
        defaultTakesBrowser: Bool, browsers: [BrowserProfile]?, drafts: ClickDrafts, draftKey: String?,
        @ViewBuilder icon: () -> Icon
    ) {
        self.title = title
        self.source = source
        self.offersDefault = offersDefault
        self.defaultCaption = defaultCaption
        self.defaultTakesBrowser = defaultTakesBrowser
        self.browsers = browsers
        self.drafts = drafts
        self.draftKey = draftKey
        self.icon = icon()
        _action = action
        let stored = action.wrappedValue
        let shown = drafts.byRow[draftKey] ?? ClickDraft(stored, offersDefault: offersDefault)
        _kind = State(initialValue: shown.kind)
        _link = State(initialValue: shown.link)
        var linked: String?, browser: BrowserProfile?, defaultBrowser: BrowserProfile?
        var app: (bundleID: String, name: String)?
        switch stored {
        case .openLink(let url, let profile):
            linked = url
            browser = profile
        case .launchApp(let bundleID, let name): app = (bundleID, name)
        case .libraryDefault(let profile): defaultBrowser = offersDefault ? profile : nil
        case nil, .showReminder: break
        }
        _linked = State(initialValue: linked)
        _browser = State(initialValue: browser)
        _defaultBrowser = State(initialValue: defaultBrowser)
        _app = State(initialValue: app)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                icon
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .lineLimit(2)
                    .help(title)
                Spacer()
                Picker(title, selection: $kind) {
                    if offersDefault { Text("Default").tag(ClickKind.byDefault) }
                    Text("Show Reminder").tag(ClickKind.reminder)
                    Text("Open a Link").tag(ClickKind.link)
                    Text("Open an App").tag(ClickKind.app)
                }
                .labelsHidden()
                .fixedSize()
            }
            switch kind {
            case .byDefault:
                if let defaultCaption {
                    Text(defaultCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if defaultTakesBrowser, !BrowserMenu.options(browsers, keeping: defaultBrowser).isEmpty {
                    browserPicker($defaultBrowser, label: Text("Open Default Link for \(title) In"))
                }
            case .reminder:
                EmptyView()
            case .link:
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Link", text: $link, prompt: Text("https://example.com"))
                        .labelsHidden()
                        .accessibilityLabel("Link for \(title)")
                        .focused($linkFocused)
                        .onSubmit(commitLink)
                    if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ClickLink.normalized(link) == nil {
                        Text("Not a valid link")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !BrowserMenu.options(browsers, keeping: browser).isEmpty,
                       (ClickLink.normalized(link) ?? linked).map(ClickLink.isWeb) ?? true {
                        browserPicker($browser, label: Text("Open Link for \(title) In"))
                    }
                }
            case .app:
                HStack {
                    Text(app?.name ?? "No App Chosen")
                        .foregroundStyle(app == nil ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button("Choose…") { choosing = true }
                        .accessibilityLabel("Choose App for \(title)")
                }
            }
        }
        .onChange(of: kind) { apply() }
        .onChange(of: browser) {
            if kind == .link, let linked { action = .link(linked, in: browser) }
        }
        .onChange(of: defaultBrowser) {
            if kind == .byDefault, defaultTakesBrowser { action = defaultAction }
        }
        .onChange(of: linkFocused) {
            if !linkFocused { commitLink() }
        }
        .onDisappear {
            commitLink()
            keepDraft()
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.application]) { result in
            if case .success(let url) = result { chose(url) }
        }
        .fileDialogDefaultDirectory(URL(filePath: "/Applications"))
        .fileDialogMessage("Choose the Mac app to open when you click a notification from \(source).")
        .fileDialogConfirmationLabel("Choose")
    }

    private func apply() {
        switch kind {
        case .byDefault:
            linked = nil
            // Choosing Default drops a profile its picker hides, so it never acts unseen once the
            // default turns into a web link; opening the settings keeps it.
            if !defaultTakesBrowser { defaultBrowser = nil }
            action = defaultAction
        case .reminder:
            linked = nil
            action = reminder
        case .link:
            linked = ClickLink.normalized(link)
            if let linked { link = linked }
            action = linked.map { .link($0, in: browser) } ?? reminder
        case .app:
            linked = nil
            if let app {
                action = .launchApp(bundleID: app.bundleID, name: app.name)
            } else {
                action = reminder
                choosing = true
            }
        }
    }

    private var reminder: ClickAction? { offersDefault ? .showReminder : nil }

    private var defaultAction: ClickAction? { defaultBrowser.map { .libraryDefault(in: $0) } }

    private func browserPicker(_ selection: Binding<BrowserProfile?>, label: Text) -> some View {
        HStack {
            Text("Open In")
                .fixedSize()
                .accessibilityHidden(true)
            Spacer()
            BrowserMenu(label: label, selection: selection, browsers: browsers, noneTitle: "Default Browser")
        }
        .padding(.top, 4)
    }

    // An invalid link is not saved and the last one stays in effect; a cleared field shows it again.
    private func commitLink() {
        guard kind == .link else { return }
        if let url = ClickLink.normalized(link) {
            link = url
            linked = url
            action = .link(url, in: browser)
        } else if link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let linked {
            link = linked
        }
    }

    // Called once the row is gone, so it never fights the row's own writes; the store is read live.
    private func keepDraft() {
        let shown = ClickDraft(kind: kind, link: kind == .link ? link : "")
        drafts.keep(shown == ClickDraft(action, offersDefault: offersDefault) ? nil : shown, for: draftKey)
    }

    private func chose(_ url: URL) {
        guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { return }
        let name = bundle.displayName ?? url.deletingPathExtension().lastPathComponent
        app = (bundleID, name)
        if kind == .app { action = .launchApp(bundleID: bundleID, name: name) }
    }
}

private struct BrowserMenu: View {
    let label: Text
    @Binding var selection: BrowserProfile?
    let browsers: [BrowserProfile]?
    let noneTitle: LocalizedStringKey

    // At its own width where the row has room; otherwise it takes what the row leaves and truncates
    // its title, so a long profile name never widens the window. The priority keeps an HStack from
    // halving its share with the Spacer.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.fixedSize()
            picker
        }
        .layoutPriority(1)
    }

    private var picker: some View {
        Picker(selection: $selection) {
            Text(noneTitle).tag(BrowserProfile?.none)
            ForEach(Self.options(browsers, keeping: selection), id: \.self) { profile in
                Text(title(profile)).tag(Optional(profile))
            }
        } label: {
            label
        }
        .labelsHidden()
    }

    // The stored profile stays listed while its browser or the profile itself is gone, so the
    // choice is still visible; clicking then shows the reminder.
    static func options(_ browsers: [BrowserProfile]?, keeping selected: BrowserProfile?) -> [BrowserProfile] {
        let browsers = browsers ?? []
        guard let selected, !browsers.contains(selected) else { return browsers }
        return browsers + [selected]
    }

    private func title(_ profile: BrowserProfile) -> String {
        let name = "\(ChromiumBrowser.named(profile.bundleID)?.name ?? profile.bundleID) — \(profile.directory)"
        return browsers?.contains(profile) == false ? "\(name) (Not Found)" : name
    }
}
