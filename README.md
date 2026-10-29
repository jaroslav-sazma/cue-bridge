# Cue: Relay & Reply

Cue: Relay & Reply is a small app in your Mac's menu bar: the Mac half of the Mac bridge of
[Cue: React & Act](https://github.com/jaroslav-sazma/cue-launcher), a launcher for Android phones.
With your phone paired, the phone's notifications appear in the Mac's Notification Center, where you
can answer and close them; text you copy on the Mac lands on the phone's clipboard, and text you
send from the phone lands on the Mac's; the phone can lock the Mac, and the Mac can lock itself once
the phone leaves.

The phone and the Mac talk to each other directly — over Bluetooth while they are close, and over
your own Wi-Fi for the content, or over Bluetooth alone where they share no network. The Mac app
does nothing on its own: it needs a phone with Cue: React & Act.

- **Private by design.** No account, no cloud, no server, no telemetry. The app never connects to
  the internet: it talks only to your paired phone, end-to-end encrypted, and everything stays on
  your two devices.
- **Easy on the phone's battery.** The Mac does the work and the phone only reacts when asked;
  [How it works](#how-it-works) explains the idea.
- **Your choice on the Mac.** What a click on a notification opens, whether copied text goes to the
  phone and whether the Mac locks when you walk away are settings on the Mac; which notifications
  come over is decided on the phone.
- **Free and open source.** GPL-3.0-or-later, no ads, nothing to buy.

> **Why it exists.** I built the bridge for myself. I tried several apps that connect a phone with a
> computer, and none did what I wanted: keep the two devices connected reliably, all day, and be
> optimized as far as it goes for a phone that runs on battery. So this one is built the other way
> round: the Mac does the work, and the phone only reacts when it is asked to.
>
> **Why it is free.** I made it for myself and the people close to me. If you find that it does what
> you need, you are welcome to use it freely and enjoy it: it asks for no money and collects no
> data. It comes with no warranty and no promise of support, but I use it every day and expect to
> keep tuning it so that it works. The GPL keeps it open: anyone who hands out a changed copy has to
> keep that copy open too, under a name of its own.

## Contents

- [How it works](#how-it-works)
- [Getting started](#getting-started)
- [The menu](#the-menu)
- [Pairing](#pairing)
- [Notifications](#notifications)
- [Clipboard](#clipboard)
- [Screen lock](#screen-lock)
- [What is set on the phone](#what-is-set-on-the-phone)
- [Privacy and security](#privacy-and-security)
- [Download, updates and verifying](#download-updates-and-verifying)
- [Reporting a bug](#reporting-a-bug)
- [Contributing](#contributing)
- [License](#license)

---

## How it works

The Mac waits and does the work; the phone only reacts when something happens or the Mac asks.

- **The phone does not search.** The Mac announces itself over Bluetooth and waits. On the phone,
  Android's own companion-device mechanism watches for the paired Mac and tells the launcher when it
  comes near and when it leaves, so the launcher never scans for it. Only while you pair does the
  phone look for the Mac on your Wi-Fi, for a few seconds.
- **One quiet link.** While the Mac is near, the phone keeps a single Bluetooth connection to it, at
  Bluetooth's slowest pace. Over it go only tiny encrypted signals: a "doorbell" when a notification
  arrives or goes away, a closing, a short reply, a line of copied text, whether the Mac is locked.
- **Content only when someone looks.** The text and icon of a notification the Mac fetches only
  while its display is awake. It asks the phone, and the phone opens a short connection — over the
  Wi-Fi the two share, or over Bluetooth where they share none — and closes it again about ten
  seconds after it falls quiet. A long piece of text, in either direction, travels over such a
  connection too. While you are on the launcher's home screen, the phone keeps that connection open
  instead.
- **Nothing kept awake.** The phone holds no wake locks for the bridge. While the Mac's display
  sleeps, the Mac does not call the phone in, and what arrived meanwhile is fetched in one go when
  you wake it. On the Mac, the app holds no power assertions and nothing that keeps the Mac awake;
  its timers run only while they have work — the check for closed notifications and the watch on the
  clipboard only while the display is on and unlocked and the phone is in reach, slowing down while
  nobody touches the Mac — and what changed in between is caught up on wake.

So the phone spends next to nothing on the bridge, and nothing on it has to stay awake to keep in
touch with the Mac: Android itself reports the Mac coming and going. The
[launcher's README](https://github.com/jaroslav-sazma/cue-launcher#mac-bridge) describes the phone's
side of it.

---

## Getting started

### What you need

- A Mac with Apple silicon on macOS 27 or later, with Bluetooth on.
- An Android phone with [Cue: React & Act](https://github.com/jaroslav-sazma/cue-launcher), which
  needs Android 17 or later.
- For pairing, the phone and the Mac on the same Wi-Fi network. Once paired, they no longer have to
  share one: where they cannot see each other over Wi-Fi — an office network that keeps its devices
  apart, a hotel, the phone on mobile data — everything keeps working over Bluetooth alone, just
  more slowly.

### Installing

Download `Cue-Bridge-<version>.dmg` from
[Releases](https://github.com/jaroslav-sazma/cue-bridge/releases), open it and drag **Cue Bridge**
to Applications. Start it from there; macOS asks once whether to open an app downloaded from the
internet. The app has no window and no Dock icon: it lives in the menu bar as the Cue: icon.
[Verifying a download](#verifying-a-download) shows how to check that you have the genuine build.

### Permissions

macOS asks once for each of these, at the first start or when you first pair:

- **Notifications**, to show your phone's notifications. Without it nothing appears on the Mac.
- **Bluetooth**, so that the paired phone can tell the Mac is nearby. The bridge does not work
  without it; the menu then says **Bluetooth access is not allowed**.
- **Local network**, to talk to the phone over your Wi-Fi. Pairing needs it.

If you said no, change it in System Settings: under Notifications for the first, under Privacy &
Security for the other two.

### Start at Login

The bridge works only while the app runs, so once you have paired, keep it running: **Start at
Login** in **Settings…** starts it with the Mac. If you switched Cue: off in System Settings' login
items, turning **Start at Login** on opens that pane, where only you can allow it again.

---

## The menu

The Cue: icon in the menu bar shows how things stand:

- **A crossed-out phone:** nothing is paired.
- **A plain phone:** paired, with no connection carrying content right now. That is the usual state,
  even with the phone in your pocket beside the Mac.
- **A phone with waves:** a connection to the phone is open — while content comes across, and for as
  long as the phone shows the launcher's home screen.
- **A phone with an exclamation mark:** something needs attention, and the menu says what.

Click it for the menu. Its top part tells you about the phone: **Paired with phone** and the first
eight characters of the phone's certificate, then **Phone connected**, **Phone nearby (Bluetooth)**
or **Phone not connected**, and **Mirrored:** with the number of the phone's notifications on the
Mac; or **Not paired**. A problem shows there too, such as **Bluetooth is off**, **Bluetooth access
is not allowed** or one of the [pairing problems](#when-the-menu-reports-a-problem). Below are
**Pair Phone…** or **Pair Again…**, **Unpair**, **Settings…**, **About Cue:** and **Quit Cue:**.

---

## Pairing

The order matters: a Mac that is not paired yet can be found only while it is waiting for a phone.

1. **On the Mac**, choose **Pair Phone…** in the Cue: menu (**Pair Again…** when a phone is paired
   already). The **Pair Phone** window opens and waits two minutes for your phone, counting down.
   Leave it open: closing it, or **Cancel**, ends the waiting.
2. **On the phone**, turn on the Mac bridge and tap **Find Mac**, as the
   [launcher's README](https://github.com/jaroslav-sazma/cue-launcher#mac-bridge) describes. Keep
   the phone on the same Wi-Fi as the Mac.
3. The phone shows a six-digit code, for example *482 913*, and the Mac's window asks you to **Type
   the code your phone shows**. Type it and click **Pair**. If the window says the code is not the
   one on the phone, check the digits and type them again.
4. The moment the Mac accepts the code, both sides finish pairing on their own. The window shows
   **Paired** and **This Mac's certificate**, eight characters that the phone shows under **Mac
   certificate**; the two match. If they ever differ, unpair on both sides and pair again. Click
   **Done**.

The code is how the Mac knows it is pairing with your phone: it accepts only the code your phone
shows. If pairing fails or is cancelled on either side, the window shows **Pairing ended** with the
reason, and **Try Again** starts waiting anew. If the phone says your Mac is already pairing with
another device, something else asked first: close the window and start again.

### Unpairing

**Unpair** in the Cue: menu removes the pairing from the Mac only, together with every one of the
phone's notifications in Notification Center; your [Notification Click](#what-a-click-does) choices
stay. **Unpair** on the phone, or turning its bridge off, likewise removes only the phone's side, so
unpair on both. To use the bridge again, you pair again.

### When the menu reports a problem

- **Pairing unusable: its sequence state is lost** means the Mac has lost the counters that keep
  each of its messages to the phone unique — after it was restored from a backup, for example — and
  it refuses the old pairing rather than risk repeating one.
- **Pairing was made on another Mac — pair again** means the pairing came over from another Mac, by
  Migration Assistant or a restored backup, and the Mac refuses it the same way, as two Macs must
  not share one pairing.

Either way, unpair on the phone, choose **Pair Again…** on the Mac and pair as above. The phone
guards its own counters the same way and then says so on its Mac bridge screen.

**Bluetooth is off**, **Bluetooth access is not allowed** or **Bluetooth is not working** means the
phone cannot tell that the Mac is near, so nothing comes across: turn Bluetooth on, or allow Cue:
under Privacy & Security, Bluetooth.

---

## Notifications

While the phone is near, a notification that arrives on it appears in the Mac's Notification Center
within seconds, even with the phone locked in your pocket. It shows as a notification from Cue:,
headed by the app's name and the title — *WhatsApp — Alice*, say — with the app's icon. An update
replaces the Mac's copy instead of adding another, and shows a banner again only when its text has
changed. While the Mac's display is asleep, what arrives in the meantime shows up when you wake it.

Which notifications come over, and how one whose content the phone hides looks here, is decided on
the phone: see [What is set on the phone](#what-is-set-on-the-phone).

### Replying

A notification you can answer on the phone, a message say, has **Reply** on the Mac too. What you
type there is sent through the app on the phone, as if you had answered on the phone. If it cannot
be delivered, a **Reply failed** notice says why, such as *The notification is no longer on your
phone.* or *Your phone is not connected, so the reply was not sent.* The phone confirms every reply
it delivers, and when no confirmation comes within half a minute — the phone went out of range just
then, say — **Reply not confirmed** tells you that the reply may not have arrived.

### Closing

Closing works in both directions, with one exception that comes from macOS:

- Close a notification on the phone, or let its app take it down, and it leaves the Mac as well.
- On the Mac, the **✕** on a notification and **Clear All** close it on the phone too, usually at
  once, at most a few seconds later. Should the closing get lost on the way, the Mac repeats it the
  next time the phone sends its list. If the app on the phone has meanwhile posted the notification
  again with the same text, that copy is closed as well; with new text it stays.
- **Swiping a banner aside only hides the banner.** macOS keeps the notification in Notification
  Center and tells no app about the swipe, so it stays on the phone as well. To close it, use its ✕
  in Notification Center.
- Clicking a notification closes it on the phone too when the click opens something on the Mac, such
  as an app or a website (see [What a click does](#what-a-click-does)). A click that only shows the
  reminder to continue on the phone leaves it there.

macOS does not report every closing — **Clear All** among them — so the Mac also looks through its
Notification Center for what has gone. Under **Dismissal Sync** in **Settings…**, **Check
Notification Center Periodically**, on until you turn it off, does this every 3, 5, 10 or 30 seconds
as set in **Check Every**, 5 by default, while the display is on and unlocked and the phone is in
reach; while nobody touches the Mac, the checks thin out. With it off, the closings macOS did not
report reach the phone only when the Mac wakes, unlocks or reconnects to the phone.

### What a click does

What a click on a notification does is up to you. **Notification Click** in **Settings…** lists the
apps whose notifications have reached the Mac, each set to **Default** at first, and **All Other
Apps** below them. Each can be set to:

- **Default**: many common apps come with one — their Mac app when it is installed, or else their
  website. Clicking a Google Messages notification opens Messages for web
  (`messages.google.com/web`) in your browser, say, and a WhatsApp one opens WhatsApp on the Mac if
  you have it, else WhatsApp Web. The line under **Default** says what a click will do, such as
  *Opens WhatsApp*. A default is always the same start page or app, never something taken from the
  notification. An app without a default on your Mac does what **All Other Apps** does.
- **Show Reminder**: only a reminder to continue on the phone, as the phone's app is not on the Mac.
  This is what **All Other Apps** does at first.
- **Open a Link**: a web address you type, such as `https://example.com`.
- **Open an App**: a Mac app you pick with **Choose…**.

Click a Signal notification on a Mac without the Signal app, say, and the reminder reads *Can't open
Signal here* with *Continue on your phone.* The quickest way to change what a click does is **Set
Click Action…**, which shows when you hold the pointer over the reminder: it opens the settings with
that app picked out.

With Google Chrome, Chromium, Microsoft Edge, Brave or Vivaldi on the Mac, **Open In** picks the
browser profile a link opens in, both for **Open a Link** and for a **Default** that opens a
website. The profiles are listed by their folders, such as `Default` or `Profile 1`; a browser shows
a profile's folder at the end of *Profile Path* on its version page, such as `chrome://version`.
**Default Browser**, under **All Other Apps**, picks which profile "Default Browser" means for every
web link without one of its own; **System Default** leaves it to the Mac's default browser. If the
chosen browser or profile is gone, a click shows the reminder rather than opening the link
elsewhere.

The list keeps the 30 apps seen most recently, and an app with a choice of its own is never dropped
from it. Unpairing empties the list, but your choices stay: each app comes back with them when its
next notification arrives.

### While the phone is away

When the phone leaves the Mac's range, the Mac keeps what is in its Notification Center, and nothing
new arrives. When the phone comes back, the Mac catches up with exactly what is on the phone at that
moment, with one thing the Mac remembers: what you closed there meanwhile is closed on the phone
too, and does not come back to the Mac. That holds for a day; a notification that has changed on the
phone since — a new message in the same chat, say — comes back instead, as it is news to you.

---

## Clipboard

Text you copy on the Mac is on the phone's clipboard a moment later, while the phone is near and the
Mac is awake and unlocked. **Send Clipboard to Phone** in **Settings…** turns this off from the
Mac's side; it is on until you change it. While it is off, the Mac does not watch its clipboard at
all, and what you copy meanwhile stays on the Mac even after you turn it back on. The phone has its
own switch, **Clipboard from the Mac**, and its own limit on how long a copy stays fresh while the
phone is locked, both described in the
[launcher's README](https://github.com/jaroslav-sazma/cue-launcher#mac-bridge); while that switch is
off, the Mac sends nothing either.

A copy that lands on the Mac while nobody uses it — from an iPhone over Universal Clipboard, say —
goes to the phone once you next touch the Mac's keyboard or trackpad.

Text over 100 KB stays on the Mac, and so does a clip your password manager marks as confidential,
or one a clipboard tool marks as temporary or as not copied by you.

Text goes the other way only when you send it: **Send to Mac** on the phone puts the text on the
Mac's clipboard, and the Mac shows **Sent from your phone** — *Press ⌘V to paste it.* The notice
never shows the text itself.

---

## Screen lock

The phone can lock the Mac — with **Lock the Mac** on a tile or a gesture, set up on the phone — but
never unlock it: you unlock the Mac as usual. While the phone is near, the Mac tells it whether its
screen is locked.

The Mac can also lock itself when you walk away with the phone. In **Settings…**, under **Screen
Lock**, turn on **Lock When Phone Leaves** — it is off until you do — and pick in **Lock After** how
long the phone has to be gone first: 1, 2, 5 or 15 minutes, 1 by default. The time counts from the
moment the phone's Bluetooth connection to the Mac ends; come back sooner and nothing happens. It
locks once each time the phone leaves: unlock the Mac while the phone is still away — you left it at
home, say — and the Mac stays unlocked until the phone has been back and left again. A Mac that is
already locked is left as it is, and neither turning off Bluetooth on the Mac itself nor the Mac
going to sleep counts as the phone leaving; right after a wake, the countdown can start only once
the phone has made contact again. The Mac cannot tell the phone leaving from the phone going quiet,
though: turning the Mac bridge or the phone's Bluetooth off locks the Mac after the delay as well.

**Lock When Phone Leaves** is a convenience, not a safeguard: it waits at least a minute, so keep
locking the Mac yourself where it matters.

Where macOS does not let Cue: Relay & Reply lock the screen, **Screen Lock** says so instead of
offering the settings, and **Lock the Mac** on the phone changes nothing; the phone can still see
whether the Mac is locked.

---

## What is set on the phone

Everything below lives in the launcher's Mac bridge settings and scenarios, and the
[launcher's README](https://github.com/jaroslav-sazma/cue-launcher#mac-bridge) describes it:

- turning the bridge on, pairing from the phone's side, and the permissions the phone asks for;
- which notifications reach the Mac — silent ones, for example, stay on the phone, and one whose
  content the phone's lock screen hides arrives as the lock screen shows it — with **Apps kept off
  the Mac** for those that never should, a banking app's one-time codes, say;
- **Clipboard from the Mac** and how long a copy stays fresh while the phone is locked, and **Send
  to Mac**;
- **Lock the Mac**, an action for a tile or a gesture;
- the conditions **Mac nearby** and **Mac locked**, which let scenarios on the phone follow whether
  the Mac is close and whether its screen is locked.

---

## Privacy and security

The app itself never connects to the internet; the only way it leads there is a website that a click
on a notification opens in your browser. [PRIVACY.md](PRIVACY.md) lists what crosses between the two
devices and what the Mac keeps.

[docs/security.md](docs/security.md) describes what the Mac stores, how the app is signed and whom
it trusts. To report a vulnerability, follow [SECURITY.md](SECURITY.md) rather than opening a public
issue. The protocol between the phone and the Mac has its
[spec](https://github.com/jaroslav-sazma/cue-launcher/blob/main/docs/bridge-protocol.md) in the
launcher's repository.

---

## Download, updates and verifying

Each release on the [Releases](https://github.com/jaroslav-sazma/cue-bridge/releases) page carries a
disk image, `Cue-Bridge-<version>.dmg`, and its checksum, `Cue-Bridge-<version>.dmg.sha256`. The app
inside is signed with the developer's Developer ID (team `ZMAK33FWYB`), notarized by Apple and
stapled, and so is the disk image; it is distributed outside the Mac App Store.

### Updates

The app does not update itself, and it does not check for updates: that would mean contacting a
server. To update, download the new disk image and drag **Cue Bridge** to Applications again,
replacing the old one; quit Cue: Relay & Reply first. The pairing, the settings, the macOS
permissions and **Start at Login** carry over, without pairing again.

### Verifying a download

In Terminal, in the folder with both downloaded files, check the disk image against its checksum:

```
shasum -a 256 -c Cue-Bridge-1.0.0.dmg.sha256
```

It answers `OK` after the file name when the image is intact. Then, with the app in Applications,
check its signature:

```
spctl -a -vv "/Applications/Cue Bridge.app"
codesign -dv "/Applications/Cue Bridge.app"
```

`spctl` should say the app is `accepted`, with `Notarized Developer ID` as its source and an origin
that ends in `(ZMAK33FWYB)`. `codesign` should show `Identifier=app.cue.bridge` and
`TeamIdentifier=ZMAK33FWYB`. Anything else is not a build from this repository's releases.

---

## Reporting a bug

Report bugs in the Mac app as
[issues in this repository](https://github.com/jaroslav-sazma/cue-bridge/issues), with the app's
version: **About Cue:** in the menu shows it, and so does the bottom of the **Settings…** window,
where it can be selected and copied. Say which macOS version you run and what the phone side did, if
you know. A bug on the phone's side belongs in the
[launcher's issues](https://github.com/jaroslav-sazma/cue-launcher/issues).

---

## Contributing

Bug reports and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers building the
app, the rules the code follows and the checks it has to pass.

Cue: Relay & Reply is designed, directed and tested by its maintainer, with AI coding assistants
contributing to the code.

---

## License

Cue: Relay & Reply is free software under the
[GNU General Public License, version 3 or later](LICENSE). [NOTICE](NOTICE) adds two terms under the
license's section 7: a changed copy you hand out has to be marked as different, for example with a
name and a bundle identifier of its own, and the license grants no trademark rights to the names
"Cue:", "Cue: React & Act" and "Cue: Relay & Reply" or to the Cue: icon. The bridge protocol's
specification and test vectors are dedicated to the public domain under CC0 1.0, so anyone may
implement the protocol on any platform under any license.
