import AppKit
import SwiftUI

struct SettingsView: View {
    let bridge: BridgeController
    let loginItem: LoginItem

    // Nil until read, so a stored profile does not flash as not found.
    @State private var browsers: [BrowserProfile]?
    @State private var installed: Set<String>?
    @State private var highlighted: String?
    @State private var scrollTarget: String?
    @State private var loaded = false
    @State private var drafts = ClickDrafts()

    var body: some View {
        ScrollViewReader { scroller in
            Form {
                Section {
                    Toggle(
                        "Start at Login",
                        isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })
                    )
                }
                Section("Clipboard") {
                    Toggle(
                        "Send Clipboard to Phone",
                        isOn: Binding(get: { bridge.clipboardToPhone }, set: { bridge.setClipboardToPhone($0) })
                    )
                }
                DismissalSyncSection(reconciler: bridge.reconciler)
                ScreenLockSection(bridge: bridge)
                ClickSettingsSection(
                    clicks: bridge.clicks, icons: bridge.icons, browsers: browsers, installed: installed,
                    highlighted: highlighted, drafts: drafts
                )
                Section {
                } footer: {
                    Text(verbatim: "\(Bundle.main.displayName ?? "Cue:") \(Bundle.main.versionLabel)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                }
            }
            .formStyle(.grouped)
            // A reopened window shows what is stored, even where SwiftUI kept the rows' state. Each
            // drafts object is made while the previous one is alive, so the two never share an
            // address.
            .id(ObjectIdentifier(drafts))
            // A grouped form builds its rows lazily, so what reaches beyond one row hangs here
            // rather than on a row that may not exist yet.
            .onChange(of: bridge.clicks.focus, initial: true) {
                guard let focus = bridge.clicks.focus else { return }
                bridge.clicks.focus = nil
                highlighted = focus
                scrollTarget = focus
            }
            // Only once onAppear has read the browsers and apps, which change the rows' heights; a
            // request that came while the window was closed waits for it. Deferred a turn more for
            // the rows to be laid out.
            .task(id: loaded ? scrollTarget : nil) {
                guard loaded, let target = scrollTarget else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation { scroller.scrollTo(target, anchor: .center) }
                scrollTarget = nil
            }
        }
        .frame(minWidth: 300, idealWidth: 310, maxWidth: .infinity, minHeight: 320, idealHeight: 680, maxHeight: .infinity)
        .background(ResizableWindow())
        // The login item can be approved or switched off in System Settings while this window is
        // closed, and a browser or a Mac app installed or removed.
        .onAppear {
            loginItem.refresh()
            browsers = InstalledBrowsers.profiles()
            installed = bridge.clicks.library.bundleIDs.filter(ClickLauncher.isInstalled)
            loaded = true
        }
        .onDisappear {
            highlighted = nil
            loaded = false
            scrollTarget = nil
            drafts = ClickDrafts()
        }
    }
}

// The Settings scene's window is made without .resizable in its style mask, and
// windowResizability(.contentMinSize) only sets the size limits, so its edges would not resize.
// Applied again on every update in case SwiftUI resets the mask. A resizable window would also
// offer full screen, which a menu-bar app's settings have no use for.
private struct ResizableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowHook() }
    func updateNSView(_ nsView: NSView, context: Context) {
        WindowHook.makeResizable(nsView.window)
    }

    private final class WindowHook: NSView {
        static func makeResizable(_ window: NSWindow?) {
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.collectionBehavior.insert(.fullScreenNone)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.makeResizable(window)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct DismissalSyncSection: View {
    @Bindable var reconciler: DismissReconciler

    var body: some View {
        Section {
            Toggle("Check Notification Center Periodically", isOn: $reconciler.periodic)
            Picker("Check Every", selection: $reconciler.intervalSeconds) {
                ForEach(ReconcilerMachine.intervals, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .disabled(!reconciler.periodic)
        } header: {
            Text("Dismissal Sync")
        } footer: {
            Group {
                if reconciler.periodic {
                    Text("Closing a notification here with ✕ or Clear All closes it on the phone. A closing macOS does not report is found within about \(reconciler.intervalSeconds) seconds while you use this Mac and the phone is connected.")
                } else {
                    Text("Periodic check is off: Clear All and other missed closings reach the phone only when this Mac wakes, unlocks or reconnects to the phone.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

private struct ScreenLockSection: View {
    let bridge: BridgeController

    var body: some View {
        Section {
            if bridge.canLockScreen {
                Toggle(
                    "Lock When Phone Leaves",
                    isOn: Binding(get: { bridge.autoLock }, set: { bridge.setAutoLock($0) })
                )
                Picker(
                    "Lock After",
                    selection: Binding(get: { bridge.autoLockMinutes }, set: { bridge.setAutoLockMinutes($0) })
                ) {
                    ForEach(DepartureLock.delays, id: \.self) { minutes in
                        Text(Self.label(minutes)).tag(minutes)
                    }
                }
                .disabled(!bridge.autoLock)
            }
        } header: {
            Text("Screen Lock")
        } footer: {
            Group {
                if !bridge.canLockScreen {
                    Text("This version of macOS does not let Cue: lock the screen, so this Mac cannot lock when your phone leaves. The phone can still see whether it is locked.")
                } else if bridge.autoLock {
                    Text("Locks this Mac once your phone has been out of Bluetooth range for \(Self.label(bridge.autoLockMinutes)), once each time it leaves. Turning off Bluetooth on this Mac does not count as the phone leaving.")
                } else {
                    Text("Lock this Mac when your phone leaves Bluetooth range.")
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private static func label(_ minutes: Int) -> String {
        minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }
}
