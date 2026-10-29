# Cue: Relay & Reply (app.cue.bridge) — instructions for AI executors

"Cue: Relay & Reply", the macOS side of the Cue: bridge: a menu-bar app that connects the Android
launcher "Cue: React & Act" with the Mac over the local link — notification mirroring, replies,
dismissal sync, clipboard sync, presence and the screen lock, with no cloud, relay or account.
SwiftUI, bundle id `app.cue.bridge`, display name "Cue:", GPL-3.0-or-later; Debug builds are
`app.cue.bridge.debug`, "Cue: debug". The repo is public at
https://github.com/jaroslav-sazma/cue-bridge.

## Hard rules
- macOS 27 is the deployment target and Apple silicon the only architecture (`ARCHS = arm64`). No
  legacy fallbacks, no availability checks below the floor.
- The `.app` file name never contains a colon, which Finder cannot show: the product is
  `Cue Bridge.app` and "Cue:" lives only in `CFBundleDisplayName`.
- Event-driven only: every flow starts with an OS callback. The only timers allowed are the bounded
  dismissal reconciler, the clipboard `changeCount` poll, the one-shot that removes a transient
  notice (the tap flash, the notice for a text sent from the phone) about 10 s after a user's action
  posted it, the one-shot that waits 30 s for the phone's answer to a reply the user sent, the
  one-shot the departure auto-lock arms for its set delay when the paired phone's last confirmed
  subscription ends (cancelled when the phone is back, the radio goes off, the Mac goes to sleep or
  the pairing ends) and the 200 ms one-shot that reads the screen state after a `lock` frame so the
  answering `lock-state` carries the state after the attempt — each armed only while it has work and
  the display or the connection justifies it, with tolerance, and torn down to zero scheduled work
  otherwise. The reconciler and the poll skip their pass and lengthen their own next wait, up to
  four times their interval, while no user input has come since their last pass (`IdlePacer`); that
  never adds a timer or a wakeup. The pairing timeouts, a connection's handshake and step waits and
  the 2 s grace before a closed connection is cancelled are scoped to a user-started ceremony or to
  one connection and die with it.
- Never fight sleep: no power assertion of any kind (no `IOPMAssertion`, no `ProcessInfo` activity
  that blocks idle sleep), no display wakes. When the Mac sleeps the app goes quiet and catches up
  by reconciling on wake.
- Zero third-party dependencies, ever — system frameworks only.
- The login item is registered only when the user turns on "Start at Login", never automatically.
- Logging goes through `os.Logger`, subsystem `app.cue.bridge`. Notification and clipboard content
  is never logged above debug and is `privacy: .private` by default.
- Comments are kept to a minimum: only workarounds, traps and non-obvious contracts. No descriptive
  doc comments.
- The pairing, crypto or protocol design, platform behaviour that contradicts what the code assumes,
  a protocol version bump, or a hard-to-reverse choice between architectures is not decided alone:
  stop and ask the owner.

## Language
Everything is in English, with no exception: code, identifiers, comments, UI text, commit messages,
docs, test names and assertion messages.

## Documentation
`README.md` is the user documentation of the Mac app, written for someone using it, with the labels
the app shows; the launcher's README covers the phone's side, and the two link to each other.
`CONTRIBUTING.md` is the contributor documentation: building, the rules above in human terms, tests,
debugging, signing, the release and the repository layout. `PRIVACY.md` is the privacy policy.
`SECURITY.md` says how to report a vulnerability and points to the threat model. `docs/security.md`
is what the Mac stores, how it is signed, whom it trusts and what risk remains, current state only,
never how it got there; the launcher's `SECURITY.md` and `docs/security-audit.md` point there for
the Mac's side. The protocol is never restated here.

**Every change ends with a review of these docs**, in this order:
1. Does the change touch something one of them already describes? Then update that passage — a
   behaviour change is not finished until the README matches it, a change to the build, the tests,
   the release or the rules not until CONTRIBUTING does, and a change to what the Mac stores, sends,
   signs or trusts not until `docs/security.md`, and `PRIVACY.md` where a data flow changes, do.
2. Does it not? Then judge whether it belongs in one of them: anything a user has to know, set up or
   work around goes into the README, anything a contributor has to know goes into CONTRIBUTING,
   internal refactors go into neither. If it belongs, write it in and say in the handover what was
   added and where.

Prose in every `.md` file is hard-wrapped at **100 characters**, counted in characters, not bytes.
Tables, fenced blocks and ASCII diagrams stay on one line however long they get, and a wrap never
lands inside a `code span` or a `[link](target)`, nor leaves a line starting with `- `, `+ `, `1. `,
`#` or `>`. Editing a sentence in the middle of a paragraph means re-wrapping the whole paragraph.
What a change needs checked on real hardware goes into the handover to the owner, never into a new
file.

Prose names the products in full, so the two never blur: the Mac app is "Cue: Relay & Reply", the
launcher "Cue: React & Act". A bare "Cue:" stays only where it quotes what a screen shows — the menu
bar icon and its menu, **About Cue:**, **Quit Cue:**, the app's name in System Settings and on its
notifications, the Keychain items — and where it stands for the name shared by both, as in
`NOTICE`.

## Build
```bash
xcodebuild -scheme Bridge -configuration Debug -derivedDataPath build build
xcodebuild -scheme Bridge -configuration Debug -derivedDataPath build test
```
DerivedData stays in `build/` inside the repo. Inside the sandbox xcrun prints
`couldn't create cache file` warnings; they are harmless, `** BUILD SUCCEEDED **` decides. The
source folders `Bridge/` (the app), `BridgeProtocol/` (the pure codec and the pure logic — link
stages, the state-sync diff, doorbell coalescing — compiled into the app and the tests),
`BridgeTests/` and `bridgectl/` are file-system-synchronized groups: adding a file to one needs no
`project.pbxproj` edit, a new target does. The `BridgeTests` bundle (Swift Testing) runs without the
app as host, so only `BridgeProtocol/` is testable; it never binds a port or a socket and never
touches the keychain. `#expect` cannot take a mutating call: bind the result to a `let` first.
Launching the built app binds ports and goes through Launch Services, so it is an unsandboxed step
the user approves, or the tester starts it; never enable local binding in the sandbox settings. The
app keeps its identity and pairing in the login keychain, whose ACL trusts the signature that was
let in: a Debug build is signed ad hoc and trusted by its code hash, so the first launch after a
Debug rebuild may ask once for keychain access and "Always Allow" lets the new build in; a Release
build is trusted by its team signature, which a rebuild keeps. Debug and Release share the keychain
items, `~/Library/Application Support/Cue Bridge/` and the icon cache; only the defaults, the system
permissions and the login item follow the bundle id. So only one of them runs at a time: a copy
started while either runs exits at once (`SingleInstance`).

Only the app's Release configuration is signed for real, with an Apple Development certificate of
the owner's team `ZMAK33FWYB` and the communication notifications entitlement, which only the
provisioning profile automatic signing fetches can grant; it builds only where Xcode is signed in to
that team, from the command line with `-allowProvisioningUpdates`. Debug builds and `bridgectl` stay
ad hoc and build without an account. No ad-hoc configuration may claim the communication
entitlement: a build claiming a restricted entitlement without a provisioning profile does not
launch. CONTRIBUTING's "Signing" has the settings behind this, the hardened runtime among them.

A build for anyone else comes only from `tools/release.sh`, run by the owner in Terminal; it needs
the owner's Developer ID certificate, notary credentials and Apple's servers, so an agent never runs
it. CONTRIBUTING's "Release" describes the setup and the run. The version is `MARKETING_VERSION` and
the build number `CURRENT_PROJECT_VERSION`, set alike in the app's and the tests' configurations;
every image handed out gets a new build number.

Commits: Conventional Commits, in English, ending with the trailer
`Co-Authored-By: Claude <noreply@anthropic.com>` — no model name. The repo is public at
https://github.com/jaroslav-sazma/cue-bridge, so every commit goes into public history. Push only
`main` and tags, by name, and only when the owner asks.

## Peer project
The Android side of the bridge lives in the repo of the launcher Cue: React & Act,
[cue-launcher](https://github.com/jaroslav-sazma/cue-launcher), checked out at
`../../Android/Launcher` from this one. The `main` branches of both repos pair, both at
`bridgeProtocolVersion 1`.
- Build the peer from the launcher repo root with `./gradlew assembleDebug` and install it on the
  emulator with `adb -e install -r app/build/outputs/apk/debug/app-debug.apk` — never on the owner's
  Pixel unasked. Gradle and adb run outside the sandbox; the launcher's CLAUDE.md, section "Running
  commands", has the rules.
- Build this side with `xcodebuild -scheme Bridge -configuration Debug -derivedDataPath build build`
  (see Build above for launching).
- The canonical protocol spec `docs/bridge-protocol.md` and the shared test vectors in
  `fixtures/bridge/` live in the launcher repo; both are CC0-1.0, not GPL (`NOTICE`,
  `LICENSES/CC0-1.0.txt`). This repo never restates the spec. It vendors a byte-identical copy of
  the vector files — the `*.json` files only; their README with the provenance lives only in the
  launcher's `fixtures/bridge/` — so a standalone clone tests out of the box: the tests read
  `BRIDGE_VECTORS_DIR`, default that copy. Never edit the copy: change the vectors in the launcher
  repo and run `tools/sync-vectors.sh` (default source the sibling `../../Android/Launcher`, or pass
  the launcher repo's path), which mirrors the JSON files and prints what changed. While the
  launcher sits beside this repo, the parity test in `VectorFileTests` fails on any JSON file that
  differs, and the tests that read the spec run; without it the parity test passes on the copy alone
  and the spec tests are skipped. `BRIDGE_LAUNCHER_DIR` points at another launcher checkout, and a
  path without one in it stands for a standalone clone. From xcodebuild both variables need the
  prefix `TEST_RUNNER_` (for example `TEST_RUNNER_BRIDGE_LAUNCHER_DIR=/nonexistent`), which
  xcodebuild strips before the tests see them. A protocol change lands as a pair of commits, one in
  each repo, carrying the same version; the Bridge half carries the synced vectors.
- Logs: macOS `/usr/bin/log stream --level debug --predicate 'subsystem == "app.cue.bridge"'` — zsh
  shadows `log` with a builtin, and debug events never reach `log show`; Android
  `adb -e logcat -s CueBridge`.
- `bridgectl` is the Debug-only CLI, built by the scheme beside the app: with a Debug build running,
  `build/Build/Products/Debug/bridgectl status`, `mirror-table` or `clipboard` print the bridge's
  state, the mirrored notifications or the clipboard publisher, `--json` the raw answer, and it
  exits 1 when no Debug app answers. CONTRIBUTING's "Debugging" lists what each one prints.
- End-to-end smoke: build both, install the launcher on the emulator, and have the owner start this
  app (the sandbox blocks `open`) and choose **Pair Phone…**. The emulator sees neither the Mac's
  Bluetooth nor its Bonjour, so it pairs over the launcher's debug path — turn on **Pair without
  Bluetooth** (it starts off), host `10.0.2.2`, and the listener port that the Debug pairing window
  and `bridgectl status` show; nothing is set on the Mac. Type the code the emulator shows into the
  pairing window. Verify with `bridgectl status` and both logs. Then turn the bridge off on the
  phone: the session ends, the phone's pairing is wiped, the log falls silent, and the launcher's
  `scripts/background-audit.sh` matches a run with the bridge on and paired. What only real hardware
  can show goes into the handover to the owner.
