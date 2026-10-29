# Contributing to Cue: Relay & Reply

Thank you for looking into it. This file is for anyone who wants to build Cue: Relay & Reply, change
it or help with a release; what it does and how to use it is in the [README](README.md). The app is
the Mac half of the bridge of [Cue: React & Act](https://github.com/jaroslav-sazma/cue-launcher),
whose repository holds the phone's half and the protocol between the two.

## Contents

- [Reporting bugs and security issues](#reporting-bugs-and-security-issues)
- [Building](#building)
- [Rules the code follows](#rules-the-code-follows)
- [Tests](#tests)
- [The protocol and the launcher](#the-protocol-and-the-launcher)
- [Debugging](#debugging)
- [Signing](#signing)
- [Release](#release)
- [Repository layout](#repository-layout)
- [Commits and pull requests](#commits-and-pull-requests)

---

## Reporting bugs and security issues

A **bug** goes into an issue in this repository. Say which version of the app you run — **About
Cue:** in the menu shows it, and so does the bottom of **Settings…**, as `1.0.0 (1)` — the macOS
version, and the version of Cue: React & Act on the phone. Then describe the steps that lead to it
and what you expected instead. A log helps: the command under [Debugging](#debugging) prints what
the app writes, without notification or clipboard content. A bug that is the phone's, not the Mac's,
goes to the [launcher's issues](https://github.com/jaroslav-sazma/cue-launcher/issues).

A **vulnerability** never goes into a public issue. [SECURITY.md](SECURITY.md) describes how to
report it privately.

---

## Building

The app is SwiftUI with system frameworks only, built for macOS 27 and Apple silicon. It needs Xcode
with the macOS 27 SDK on an Apple silicon Mac. Open `Bridge.xcodeproj`, or build from the command
line in the repository root:

```bash
xcodebuild -scheme Bridge -configuration Debug -derivedDataPath build build   # the app and bridgectl
xcodebuild -scheme Bridge -configuration Debug -derivedDataPath build test    # the tests
```

DerivedData stays in `build/` inside the repository, which is not under version control; the built
app is `build/Build/Products/Debug/Cue Bridge.app`, with `bridgectl` beside it. The source folders
are synchronized with the file system, so a new file in one of them needs no change to the project
file; a new target does.

A Debug build is the bundle `app.cue.bridge.debug`, shown as *Cue: debug*. It is signed ad hoc, so
it builds without an Apple account. The app keeps its identity and its pairing in the login
keychain, whose access list trusts the build that was let in; an ad-hoc build is trusted by its code
hash, which changes with every rebuild, so the first start after a Debug rebuild asks once per item
for keychain access, and **Always Allow** lets the new build in.

Debug and Release builds share the keychain items, `~/Library/Application Support/Cue Bridge/` and
the icon cache; only the defaults, the system permissions and the login item follow the bundle
identifier. So only one of them runs at a time: a copy started while either runs exits at once,
before it reads anything, so that two copies never seal frames under the same counters. A Release
build needs the maintainer's team to sign it, see [Signing](#signing).

---

## Rules the code follows

These are the conventions a change is reviewed against. Most of them exist because the app runs all
day in the background of someone's Mac.

- **macOS 27 and Apple silicon are the floor.** The deployment target is macOS 27 and `ARCHS` is
  `arm64`, so there is no availability check and no fallback below it.
- **Event-driven only.** Every flow starts with a callback from the system: a connection, a
  Bluetooth event, a notification closed or clicked, the Mac waking. The few timers each have one
  bounded job: the dismissal reconciler and the clipboard poll, which run only while they have work
  and the display or the connection justifies it, and which stretch their wait up to four times
  while nobody uses the Mac; one-shots that clear a short-lived notice, wait for the phone's answer
  to a reply, count down **Lock When Phone Leaves** and read the screen state after a lock; and the
  timeouts of a pairing or of one connection, which end with it. With nothing to do, the app has
  nothing scheduled.
- **Never fight sleep.** No power assertion of any kind and no display wakes. When the Mac sleeps
  the app goes quiet and catches up on wake.
- **No third-party dependencies.** System frameworks only, which is also why there is no updater.
- **The login item is the user's choice.** It is registered only when the user turns on **Start at
  Login**, never automatically.
- **Content stays out of the logs.** Logging goes through `os.Logger` under the subsystem
  `app.cue.bridge`. Notification and clipboard content, and every free-form string the phone sends,
  is logged at debug level only and marked private.
- **No colon in the file name.** Finder cannot show one, so the app is `Cue Bridge.app` and "Cue:"
  is only its display name.
- **Comments are for what the code cannot say.** A workaround, a trap or a contract that is not
  obvious gets a comment; a description of what a function does does not.
- **English everywhere.** Code, identifiers, comments, the UI text, commit messages, documentation,
  test names and assertion messages.

---

## Tests

```bash
xcodebuild -scheme Bridge -configuration Debug -derivedDataPath build test
```

`BridgeTests` is a Swift Testing bundle that runs without the app as its host. It can therefore test
only `BridgeProtocol/`, the codec and the logic that needs no system service — link stages, the
pairing ceremony, the state-sync diff, the reconciler, the clipboard and lock decisions — which is
compiled into both the app and the tests; logic worth a test belongs there. The tests never bind a
port or a socket and never touch the keychain. One trap: `#expect` cannot take a mutating call, so
bind its result to a `let` first.

The protocol's test vectors are read from `fixtures/bridge/`, a copy of the launcher's (see
[The protocol and the launcher](#the-protocol-and-the-launcher)), so a clone of this repository
tests on its own. `BRIDGE_VECTORS_DIR` reads them from another directory. `BRIDGE_LAUNCHER_DIR`
points at a launcher checkout; by default the tests look for one at `../../Android/Launcher` from
this repository's root, and a path with no launcher in it stands for a clone on its own. While a
launcher checkout is found, the parity test in `VectorFileTests` fails on any JSON file that is
missing on one side or differs by a byte, and the tests that read the spec — the protocol version,
the derivation labels, the GATT UUIDs — run; without one the parity test checks the copy alone and
the spec tests are skipped. From `xcodebuild` an environment variable reaches the tests only with
the prefix `TEST_RUNNER_`, which it strips:

```bash
TEST_RUNNER_BRIDGE_LAUNCHER_DIR=/nonexistent xcodebuild -scheme Bridge -configuration Debug -derivedDataPath build test
```

`ConversationLoopbackTests` drive the Mac's half of a session against a scripted phone over
in-memory carriers: closings lost on the way or meeting a newer post, replies and their answers,
wake-ups folding into one state-sync. A change to how a session behaves comes with a case there.

---

## The protocol and the launcher

The protocol between the phone and the Mac is specified in the launcher's
[`docs/bridge-protocol.md`][protocol], and its canonical test vectors live in the launcher's
`fixtures/bridge/`, together with their README; both are dedicated to the public domain under
CC0-1.0 (`NOTICE`, `LICENSES/CC0-1.0.txt`). This repository never restates the spec. Its
`fixtures/bridge/` holds an identical copy of the JSON vectors, which is never edited here: the
vectors change in the launcher repository, and `tools/sync-vectors.sh` copies them over — from the
sibling `../../Android/Launcher` by default, or from the path given as its only argument — and
prints what changed. A protocol change lands as a pair of commits, one in each repository, carrying
the same `bridgeProtocolVersion`; this one carries the Swift code and the synced vectors. The
launcher's CONTRIBUTING, section [The Mac bridge and its macOS app][launcher-bridge], has the rest:
what the vectors cover, the change policy that decides the version and the tests on the phone's
side.

---

## Debugging

**Logs.** The app logs under the subsystem `app.cue.bridge`:

```bash
/usr/bin/log stream --level debug --predicate 'subsystem == "app.cue.bridge"'
```

The full path matters in zsh, whose builtin `log` shadows the system tool, and debug events reach
only `log stream`, never `log show`. The phone logs under the tag `CueBridge`
(`adb logcat -s CueBridge`).

**`bridgectl`.** A small command-line tool, built by the scheme beside the app, reads the state of a
running Debug build:

- `bridgectl status` prints the protocol version; the pairing — the peer's fingerprint prefix, or
  `unusable` with the reason: the sequence state lost, or the pairing made on another Mac — and
  pairing mode with its step; the listener port; Bonjour with its TXT record (`v=1`, plus `pair=1`
  in pairing mode); the connection state with the peer's endpoint; the Bluetooth peripheral
  (`advertising`, `off`, `starting`, the radio's state such as `powered off` or `unauthorized`, or
  the failure); the L2CAP channel (`published` with its PSM, `not published`, `publishing`, or the
  failure) and the session's carrier (`over tcp` or `over l2cap`); whether a central is subscribed
  over Bluetooth while paired, with what payload, and whether it is confirmed as the phone
  (`confirmed` or `subscribed, not confirmed`: only a frame that central wrote itself and the Mac
  accepted confirms it, and a central whose MTU is below 185 shows as not subscribed); the type and
  age of the last signal sent and received over GATT; the last state-sync with its added, updated,
  removed and untouched counts; the number of mirrored notifications; the dismissal reconciler,
  `periodic` or `event-only`, its interval, and `armed` or `disarmed` with the reason; and a storage
  error when there is one.
- `bridgectl mirror-table` prints one line per mirrored notification: key hash, package, thread
  identifier, whether an icon is attached (`pending` for one held back until its icon arrives), and
  the title and body as shown — content, which is why the tool exists only in Debug builds.
- `bridgectl clipboard` prints the clipboard publisher, `armed` or `idle` with the reason, the
  pasteboard access behaviour, the last `changeCount` it read, the last clip sent and the last
  received — direction, message type, byte size, `sensitive`, `announce` and age, never the text —
  the last reason a clip was skipped and the number of live echo tombstones.

`--json` prints the raw answer of any of them. The tool talks to the app over
`~/Library/Application Support/Cue Bridge/debug/bridgectl.sock` (directory 0700, socket 0600) in a
line-JSON protocol internal to this repository, and exits 1 when no Debug app answers. Release
builds compile the server out.

**Pairing with an emulator.** The Android emulator sees neither the Mac's Bluetooth nor its Bonjour,
so a debug build of the launcher can pair without either. Build and install it as the launcher's
CONTRIBUTING describes, start the Debug app here and choose **Pair Phone…**. In the launcher's Mac
bridge settings, turn on **Pair without Bluetooth**, keep `10.0.2.2` as the host — the Mac the
emulator runs on — and enter the port the Mac listens on, which the Debug pairing window and
`bridgectl status` show; nothing is set on the Mac. Tap **Pair** and type the code the emulator
shows into the Mac's pairing window. The emulator's Wi-Fi has to be on. Everything but the Bluetooth
link with its L2CAP channel, the phone's companion-device presence and battery use can be exercised
this way; those need a real phone next to a real Mac.

---

## Signing

Only the app's Release configuration is signed for real: automatically, with an Apple Development
certificate of the maintainer's team `ZMAK33FWYB`, and with
`Bridge/CommunicationNotifications.entitlements`, which claims
`com.apple.developer.usernotifications.communication`. That entitlement shows a mirrored message
with its sender's name and icon, and only a provisioning profile can grant it, so a Release build
works only where Xcode is signed in to the team and the Mac is registered with it; from the command
line it needs `-allowProvisioningUpdates`. A fork that signs its own builds uses its own team and,
as `NOTICE` asks, a bundle identifier other than `app.cue.bridge`.

Release builds run under the hardened runtime and without `get-task-allow`:
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` keeps the debugger entitlement out, and because Xcode
drops `ENABLE_HARDENED_RUNTIME` for an ad-hoc signature,
`OTHER_CODE_SIGN_FLAGS = "--options=runtime"` sets it for `bridgectl` and repeats it, harmlessly,
for the app. `codesign -dv --entitlements -` on a built app shows the authority, the team, the
runtime flag and the entitlements.

Debug builds and `bridgectl` are signed ad hoc and need no account. Debug builds run without the
hardened runtime, because Xcode moves a Debug build's code into a separate ad-hoc signed library
that library validation would refuse to load, and Xcode adds `get-task-allow` for the debugger. They
carry no entitlement either: a build that claims a restricted entitlement without a provisioning
profile does not launch. What this means for the keys the app holds is in
[docs/security.md](docs/security.md).

---

## Release

A build for anyone else is a disk image signed with the team's Developer ID, notarized by Apple and
stapled, outside the Mac App Store. Only the maintainer can make one: `tools/release.sh` does all of
it with the team's certificate and notary credentials.

### The version

`MARKETING_VERSION` is the version people see (`CFBundleShortVersionString`) and
`CURRENT_PROJECT_VERSION` the build number (`CFBundleVersion`); both are set alike in the Debug and
Release configurations of the app and the tests, and **About Cue:** and **Settings…** show them as
`1.0.0 (1)`. A new version raises `MARKETING_VERSION` by [Semantic Versioning](https://semver.org/)
and the build number by one. Every image handed out carries a build number of its own: the script
refuses a version and build whose image is still in `build/release/`. A run whose image goes to
nobody is a rehearsal, and deleting its folder lets the same version and build run again.

### One-time setup

1. **Developer ID Application certificate.** Xcode › Settings › Accounts › the team › **Manage
   Certificates…** › **+** › **Developer ID Application**. Only the team's Account Holder can create
   it. Created there, its private key stays in the login keychain, which the script needs to sign
   the disk image; a certificate Xcode manages in the cloud would sign the app but not the image. It
   is valid for five years. Export it with its key to a password-protected `.p12` kept off the Mac:
   a team gets only a few Developer ID certificates, and a revoked one can make Gatekeeper refuse
   what it signed.
2. **Notary credentials.** An app-specific password from `account.apple.com` › Sign-In and Security
   › App-Specific Passwords, then once in Terminal
   `xcrun notarytool store-credentials cue-notary --apple-id <Apple ID> --team-id ZMAK33FWYB`,
   pasting the password when asked. The credentials go into the login keychain under the profile
   `cue-notary`; the environment variable `NOTARY_PROFILE` names another.
3. **The Developer ID profile.** Nothing to do by hand: the first export with
   `-allowProvisioningUpdates` has Xcode create a Developer ID provisioning profile for
   `app.cue.bridge` with Communication Notifications. The current one is valid until 2044-10-23.

### A release run

In Terminal, outside any sandbox, from the repository root, with everything committed:

```bash
tools/release.sh
```

The script refuses a working tree with uncommitted changes, a missing Developer ID certificate of
the team, or notary credentials that do not work. It archives the Release configuration and exports
the archive with `tools/ExportOptions.plist` (`developer-id`, automatic signing, team `ZMAK33FWYB`),
which re-signs the app with the Developer ID certificate, a secure timestamp and the Developer ID
profile. It checks the export — a valid signature, the Developer ID authority and team, the hardened
runtime, the timestamp, the communication notifications entitlement, no `get-task-allow` and the
version from the project — sends the app to the notary service and staples it. A disk image then
holds the app, a link to `/Applications`, `LICENSE` and `NOTICE`, and is signed, notarized and
stapled in turn; Gatekeeper's assessment of both closes the run. Each notarization announces itself
and then waits silently for Apple's verdict, which can take tens of minutes. Signing the image may
ask once whether `codesign` may use the Developer ID key; **Always Allow** lets later runs through.

Everything lands in `build/release/<version>-<build>/`: `Cue-Bridge-<version>.dmg` with its
`.sha256`, the exported app and `Bridge.xcarchive`, whose dSYM symbolicates a crash report from that
build. `build/` is not under version control, so the archive and the image are copied somewhere
lasting. The last lines give the version, the commit and the embedded profile's expiry; that commit
gets the tag `v<version>`.

A local Release build (`xcodebuild … -configuration Release build`) stays signed with the Apple
Development certificate and runs only on a Mac registered to the team; only the script's export is
for others.

### Before handing the image to anyone

- **Source.** The app is GPL-3.0-or-later, so whoever receives the image must be able to get the
  corresponding source (section 6): this repository at the tagged commit, or the source handed over
  with the image. The image carries `LICENSE` and `NOTICE`.
- **A first install.** On a Mac or a user account that never ran Cue: Relay & Reply, open the image
  from a download (a browser or AirDrop, so that it is quarantined), drag Cue Bridge to Applications
  and start it. Gatekeeper should ask only whether to open an app downloaded from the internet. Then
  pair a phone, have it mirror a message, reply to it from the Mac and check that its banner shows
  the sender's name and the app's icon, which only the communication entitlement gives.
- **The maintainer's own Mac.** The Developer ID build is not the build the keychain let in, so its
  first start asks once per item for access, and macOS may ask again for Bluetooth and
  notifications.

### Updates

There is no updater: it would be a third-party framework or a network service. A new version is
downloaded and replaces the app in Applications. Its bundle identifier and Developer ID signature
stay the same, so its designated requirement does too, and the keychain items, the permissions and
the login item carry over without asking.

---

## Repository layout

| Path | Contents |
|---|---|
| `Bridge/` | the app: menu, settings and pairing window; the TLS listener, Bonjour, the Bluetooth peripheral and its L2CAP channel (`Transport/`); the notification mirror and click actions (`Mirror/`), with the bundled click library `ClickLibrary.json`; the clipboard (`Clipboard/`); the keychain and the stored state (`Storage/`); the `bridgectl` server (`Debug/`); the icon and the entitlements of the Release build |
| `BridgeProtocol/` | the codec, the crypto and the pure logic — pairing, link stages, transports' framing, the state-sync diff, the reconciler, clipboard and lock decisions — compiled into the app and the tests |
| `BridgeTests/` | the Swift Testing bundle, vector tests and loopback sessions included |
| `bridgectl/` | the debug command-line tool, a client of the server in Debug builds |
| `Support/Bridge-Info.plist` | the app's extra Info.plist keys: its Bonjour service type and the message intent it donates |
| `tools/release.sh`, `tools/ExportOptions.plist` | the release script and its Developer ID export options |
| `tools/sync-vectors.sh` | copies the protocol vectors from the launcher repository |
| `fixtures/bridge/` | the protocol's test vectors, a copy of the launcher's canonical JSON files; CC0-1.0, not GPL |
| `docs/security.md` | what the Mac stores, how it is signed, whom it trusts and the risks that remain |
| `README.md` | the user documentation |
| `CONTRIBUTING.md` | this file |
| `SECURITY.md` | how to report a vulnerability, with pointers to the threat model |
| `PRIVACY.md` | the privacy policy |
| `LICENSE`, `NOTICE`, `LICENSES/` | the GPL text; the license notice with its section 7 terms and the CC0 dedication of the vectors; the CC0 text |
| `CLAUDE.md` | conventions for AI executors working in this repository |

---

## Commits and pull requests

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) and are in
  English: `feat: …`, `fix: …`, `docs: …`, `refactor: …`, `test: …`, `build: …`.
- Keep a pull request to one concern. Before opening it, run the tests and read the README, this
  file and `docs/security.md` against the change: a behaviour a user sees is not finished until the
  README describes it, a change to the build, the tests or the rules above not until this file does,
  and a change to what the Mac stores, sends, signs or trusts not until `docs/security.md` does —
  and `PRIVACY.md` when a data flow changes. Prose in every `.md` file is hard-wrapped at 100
  characters; tables and fenced blocks stay on one line.
- A change to the protocol starts in the launcher repository, as described under
  [The protocol and the launcher](#the-protocol-and-the-launcher).
- Contributions are accepted under the project's license, GPL-3.0-or-later. The vectors in
  `fixtures/bridge/` are CC0-1.0 and change only in the launcher repository.

[protocol]: https://github.com/jaroslav-sazma/cue-launcher/blob/main/docs/bridge-protocol.md
[launcher-bridge]: https://github.com/jaroslav-sazma/cue-launcher/blob/main/CONTRIBUTING.md#the-mac-bridge-and-its-macos-app
