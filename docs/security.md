# Security of the Mac app

What Cue: Relay & Reply, the Mac half of the bridge, stores, how it is signed, how it decides whom
to trust, and the risks that remain, seen from the Mac. The protocol itself — pairing, TLS pinning,
the frame and record crypto, the replay window, what crosses in each direction — is specified in the
launcher repository's [`docs/bridge-protocol.md`][protocol]. That repository's
[`docs/security-audit.md`][audit] is the full audit: its section 12 reviews the protocol and the
phone's half and points here for the Mac's own. This file repeats neither.

## What the Mac stores

| What | Where | Protection | Removed |
|---|---|---|---|
| TLS identity: an EC P-256 private key and its self-signed certificate | login keychain: a key tagged `app.cue.bridge.identity`, and the certificate as the generic password `identity-certificate` of service `app.cue.bridge` | keychain ACL that trusts the creating code | never; a new pairing reuses it |
| Pairing: the phone's certificate fingerprint, `K_ble`, and the hardware UUID of the Mac it was made on | login keychain, generic passwords `peer-pin`, `k-ble` and `pairing-host` of service `app.cue.bridge` | keychain ACL that trusts the creating code | **Unpair**; replaced by a new pairing |
| Sequence state: the bound of the reserved outgoing numbers and the incoming replay window | `~/Library/Application Support/Cue Bridge/Sequence/state` | directory 0700 and excluded from Time Machine, file 0600; magic, SHA-256 checksum, and a tag hashed from the `K_ble` it counts for | **Unpair**; replaced by a new pairing |
| Mirrored notifications: app label, title, text, time, the phone's notification key and package | Notification Center, as the app's own notifications; the mirror's state is their `userInfo` | what macOS grants other apps over Notification Center | closed by the user or the phone; all of them at **Unpair** |
| App icons of mirrored notifications | `~/Library/Caches/app.cue.bridge/icons/<sha256>.png`, and a copy per notification handed to Notification Center from the temporary directory | directory 0700; a name is the hash of the bytes, checked on arrival | **Unpair** |
| Only in Release builds, which are signed with the communication entitlement: per mirrored notification an incoming message interaction — the app's package, its label and the notification's title as the sender's name, its icon, the thread identifier; never the text | macOS's interaction store for the app (Siri and Suggestions), donated through Intents | what macOS grants over its donated interactions | **Unpair** |
| Settings: the listener port, the phone's last clipboard switch, **Send Clipboard to Phone**, **Dismissal Sync**, **Lock When Phone Leaves** and its delay | the app's defaults, `app.cue.bridge` | none needed: no secret | the phone's switch at **Unpair**; the rest stays |
| **Notification Click**: the user's click actions — a link, for a web link optionally the Chromium browser profile it opens in (the browser's bundle identifier and the profile's folder), a Mac app's bundle identifier and name, or, for one phone app, an explicit choice to show the reminder — per phone app's package and one for all other apps; an app left at **Default** stores nothing, or only the browser profile a web link of its library default opens in; and once for all apps the browser profile **Default Browser** stands for, none meaning the system's default browser | the app's defaults, `app.cue.bridge`, key `clickRoutes` | none needed: no secret | stays at **Unpair** |
| The phone apps seen in mirrored notifications, for **Notification Click** to list: package, label, icon hash and when last seen; at most 30, the oldest dropped first unless it has a click action of its own | the app's defaults, `app.cue.bridge`, key `clickSeenApps`; the icons are the cached ones above | none needed: no secret | **Unpair** |
| Debug builds only: the `bridgectl` socket | `~/Library/Application Support/Cue Bridge/debug/bridgectl.sock` | socket directory 0700, socket 0600 | with the app |

Clipboard text lives only for one pass of the poll or one write to the pasteboard; replies and
pending closings live in memory.

Debug builds are the bundle `app.cue.bridge.debug`: their defaults (`app.cue.bridge.debug` in the
table's place), notification and Bluetooth permissions and login item are their own, while the
keychain items, the files and the icon cache above are shared with Release. A copy of either that
starts while another runs exits before it reads any of them, so two copies never seal frames under
the same counters.

## Keychain and signing

The keys live in the file-based login keychain. The data protection keychain needs a restricted
entitlement that an ad-hoc signature cannot carry, and Debug builds, which share the items, stay ad
hoc. Each item's ACL trusts the code the user let in. A team-signed build is let in by its
designated requirement, which a rebuild keeps: for the distributed build the identifier
`app.cue.bridge` under a Developer ID certificate of the team `ZMAK33FWYB`, for the owner's local
Release build the same identifier under the owner's Apple Development certificate. The two differ,
so each asks once. A Debug build is let in by its code hash, so the first launch after every Debug
rebuild asks once per item. Any other program asking for the items gets the same prompt.

The build for others is exported from a Release archive with the team's Developer ID certificate, a
secure timestamp and a Developer ID provisioning profile, then notarized and stapled, and so is the
disk image that carries it (`CONTRIBUTING.md`, "Release"). The owner's local Release builds are
signed with an Apple Development certificate and launch only on a Mac registered to the team. Both
carry one entitlement, `com.apple.developer.usernotifications.communication`, which their
provisioning profile grants. They run under the hardened runtime (`--options=runtime`) and without
`get-task-allow`: macOS refuses injected libraries (`DYLD_INSERT_LIBRARIES` and libraries signed by
neither Apple nor the team) and gives no other process of the user the app's task port, so its
memory — the keys among it — cannot be read or patched from outside without root. The app is not
sandboxed, which a click action's browser profile relies on: a sandboxed app passes no arguments to
an app it launches. Debug builds are signed ad hoc and run without the hardened runtime: Xcode moves
a Debug build's code into a separate ad-hoc signed library, which the runtime's library validation
refuses to load — two ad-hoc images have no team identifier in common — and Xcode adds
`get-task-allow` for the debugger.

## Hardware binding

A pairing is stored with the hardware UUID (`IOPlatformUUID`) of the Mac that made it. At start the
Mac reads the binding before the key: a pairing whose UUID differs, is missing, or cannot be
compared because this Mac's UUID cannot be read never loads its key. Nothing is sent or accepted
under it, the listener and the pairing's Bluetooth service stay down, and the menu shows **Pairing
was made on another Mac — pair again** with **Pair Again…** and **Unpair**. A pairing whose sequence
state is missing, unreadable or another key's is held back the same way and shows **Pairing
unusable: its sequence state is lost**. A Mac whose UUID cannot be read refuses to start pairing at
all.

This keeps one pairing from living on two Macs. A keychain carried over by Migration Assistant or
restored from a backup onto another Mac would otherwise give a second Mac `K_ble` and the counters
that go with it, and both would seal frames under the same key and the same sequence numbers: nonce
reuse, and frames each would accept from the other's past. The TLS identity is not bound. A copy of
it on another Mac presents the Mac's certificate, but without the pairing it pins no phone, and the
phone's own identity is new with every pairing, so the copy opens no session.

## Trust from the Mac's side

- **Pairing** happens only in pairing mode, which the Mac's user starts from the menu and which
  lasts 120 seconds; the first `pair-request` uses it up, and a second phone meanwhile is answered
  `busy`. The phone commits to its key before the Mac creates its own, and the Mac's user types the
  code the phone shows; the Mac compares it in constant time and commits only once the code is right
  and the phone's proof checks out. The phone's bridge settings and the Mac's pairing window then
  show the first eight hex digits of the Mac's certificate fingerprint, so the user can compare the
  phone's pin with this Mac's certificate.
- **Network sessions** are TLS 1.3 only, mutually authenticated, without resumption. Outside pairing
  mode the Mac accepts exactly the phone's leaf certificate it pinned, by SHA-256 over its DER
  bytes. At most eight connections may be in their handshake, three from one address; a new one
  closes the oldest.
- **Bluetooth.** Frames are sealed under `K_ble`, with the sequence numbers kept in the file above
  and checked against a 64-entry window. A GATT subscriber counts as the phone only once a frame it
  wrote itself has been accepted; until then it gets nothing but the sealed summon. An L2CAP channel
  authenticates by `K_ble` and has two slots of its own for channels in their handshake.
- **Input.** The first frame on a connection must be `hello`: any other, an unknown type included,
  closes the connection. After `hello` an unknown type is ignored, so a newer phone can add
  messages; a malformed frame closes the connection.
- **Clipboard.** The Mac reads its pasteboard only while its own **Send Clipboard to Phone** is on
  (it is until the user turns it off), the phone's last `hello` took clips, a way to the phone is up
  and the Mac is awake and unlocked. A copy made while **Send Clipboard to Phone** was off stays on
  the Mac when the switch is turned back on. Clips marked concealed, transient or auto-generated are
  skipped before their text is read.
- **Screen lock.** The phone can ask the Mac to lock its screen, never to unlock it, and learns
  whether the screen is locked: when that changes, when its subscription is confirmed, on every
  session and in answer to every request to lock. The Mac locks through `SACLockScreenImmediate`,
  private API of `login.framework`, which it looks up at run time and never links; where macOS lacks
  it a request to lock changes nothing and **Lock When Phone Leaves** is unavailable. That setting
  is off until the user turns it on. It locks the Mac once the last confirmed Bluetooth subscription
  has been gone for the chosen delay, one minute at the least. This Mac's own sleep, its Bluetooth
  going off or its Bluetooth service added again, an unpairing or a new pairing does not count as
  the phone leaving, and only a subscription confirmed after it counts again; the sleep also cancels
  a lock still waiting. A screen already locked is left alone, and each departure locks at most
  once.
- **Notification click.** A click on a mirrored notification opens only what the Mac's user chose
  under **Notification Click** or, for an app left at **Default**, what the library bundled with the
  app lists for that app: a fixed https link, Mac apps by bundle identifier, or both. A library
  default opens the first of its Mac apps that is installed, else its link. The phone's package name
  only picks among those choices and the library's entries; nothing the phone sends names a link or
  an app to open, and nothing from a notification goes into a link. An app the library does not
  list, or whose entry has nothing for this Mac, does what the choice for all other apps does, and
  **Show Reminder** chosen for an app stops both. When an app has no action of its own, no library
  default on this Mac and no action for all other apps, or when the chosen app is gone or no app
  opens the link, the Mac shows its reminder to open the notification on the phone. An app left at
  **Default** can also keep a browser profile for its library default's link, which is decided at
  the click like the default itself: the link opens in that profile, a Mac app ignores it. **Default
  Browser** under **Notification Click** names the profile that every web link without one of its
  own opens in — an app's own link, its library default's, the one for all other apps — and leaves
  it to the system's default browser while it names none; a link with another scheme or a Mac app
  ignores it. A web link chosen to open in a browser profile, its own, its default's or the one
  **Default Browser** names, opens there or not at all. The Mac reads nothing of the browser's data:
  when **Settings** opens and again at the click it only looks up whether the folders `Default` and
  `Profile 1` to `Profile 100` exist in the browser's data folder, so the profiles go by their
  folders' names. It launches a new instance of the browser with `--profile-directory` and the link
  as arguments, which hands both to a copy already running. A browser or profile that is gone brings
  the reminder instead of the link in another profile, and a folder that does not exist never
  reaches the browser, which would create an empty profile under that name.
- **Logs** go to `os.Logger` under `app.cue.bridge`. Notification and clipboard content is logged at
  debug level only and private. So is every free-form string the peer controls — an unknown message
  type, a `bye` reason, a reply error's reason, a decoder error that may quote a type — while key
  hashes, validated as 16 hex digits, and the Mac's own names for messages and states stay public.

## `bridgectl` in Debug builds

Debug builds serve `bridgectl` over the socket listed above: `status` (pairing, listener, Bonjour,
Bluetooth, connection, the last state-sync), `mirror-table` (every mirrored notification's key hash,
package, title and body) and `clipboard` (the publisher's state and the last clips' metadata, never
their text). The socket is owner-only, so every process of the same user can read the mirrored
notifications through it. Release builds compile the server out.

## Residual risks

- **Code running as the same user, in Debug builds.** Without the hardened runtime and with
  `get-task-allow`, it can attach a debugger with the developer tools' consent or launch the app
  with an injected library, and read `K_ble` and the identity key from memory; `bridgectl` hands it
  the mirrored notifications. Debug builds are for development.
- **Code running as the same user, in Release builds.** It cannot read the app's memory, and the
  keychain asks the user before it hands the keys to anything but the builds the user let in. It
  can read and write the user's files: the icons, the defaults — among them the click actions, so it
  can pick what a click on a notification opens — and the sequence file, whose tag it cannot forge
  without `K_ble` but whose older copy it can put back. The Mac would then spend sequence numbers
  again under the same key — nonce reuse — and accept old frames once more, until the next pairing.
- **Theft of what the Mac stores.** The phone treats the paired Mac as the user's own device, so a
  stolen secret acts as that Mac:

| Taken from the Mac | What it gives | What it does not |
|---|---|---|
| `K_ble` alone | in Bluetooth range, frames and L2CAP sessions as either side: posing as the phone, the closings, replies and clips the Mac sends, whether its screen is locked, and locking it; posing as the Mac under its Bluetooth address, the phone's mirrored notifications, closing and answering them, and the phone's clipboard while it takes clips | sessions over the network, which need the pinned certificates; a new pairing; anything the phone's mirror filter keeps back |
| the TLS identity key alone | on the network, posing as the Mac when the phone connects: the phone's mirrored notifications, replies through them and the phone's clipboard | Bluetooth frames and closings, sealed under `K_ble`; posing as the phone |
| both | everything the paired Mac can do | anything beyond the bridge |
| the phone's certificate fingerprint, the sequence file, the icons | nothing secret | — |

- **Lock When Phone Leaves is a convenience, not a safeguard.** It waits at least a minute, and a
  holder of `K_ble` in Bluetooth range keeps the Mac from locking by holding a confirmed
  subscription.
- **The hardware UUID is not a secret.** The binding guards against a pairing that moved to another
  Mac by migration or restore, not against someone who copies the keychain on purpose and reports a
  forged UUID; that person already holds the user's unlocked login keychain.
- **Signing.** The distributed build is notarized, so Gatekeeper opens it after the usual question
  for an app from the internet. Its Developer ID certificate lasts five years, and the secure
  timestamp keeps a build signed while the certificate was valid running after it expires, unless
  Apple revokes it. Its embedded Developer ID profile is valid until 2044-10-23. The owner's local
  Release build runs only on Macs registered to the team; its certificate and profile last a year
  and are renewed only with an active membership, and once the profile expires it does not launch
  until it is rebuilt. Communication notifications act only while the running binary carries
  `com.apple.developer.usernotifications.communication`, read at start, and then nothing new crosses
  the bridge: the sender's name and icon, already on the Mac, are handed to macOS's interaction
  store as well. Debug builds stay ad hoc, so the keychain asks again after every Debug rebuild.

[protocol]: https://github.com/jaroslav-sazma/cue-launcher/blob/main/docs/bridge-protocol.md
[audit]: https://github.com/jaroslav-sazma/cue-launcher/blob/main/docs/security-audit.md
