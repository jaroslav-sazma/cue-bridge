import AppKit
import os

// Release and Debug share the keychain items, the sequence state and the Bluetooth service, so a
// second copy of either would seal frames under the counters the first one holds. Clicking a
// mirrored notification makes Launch Services open the app for its bundle identifier, which can
// start another copy on disk. The copy already running wins; the new one exits before it touches
// any of the shared state.
enum SingleInstance {
    static let bundleIdentifiers = ["app.cue.bridge", "app.cue.bridge.debug"]

    static func exitIfAnotherRuns() {
        let me = ProcessInfo.processInfo.processIdentifier
        let other = bundleIdentifiers
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .first { $0.processIdentifier != me && !$0.isTerminated }
        guard let other else { return }
        Logger(subsystem: "app.cue.bridge", category: "app").info(
            "another instance runs (\(other.bundleIdentifier ?? "?", privacy: .public) pid \(other.processIdentifier, privacy: .public)), exiting"
        )
        exit(0)
    }
}
