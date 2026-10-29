# Privacy Policy — Cue: Relay & Reply

*Last updated: 2026-10-29. Applies to the macOS app `app.cue.bridge`, the Mac half of the Mac bridge
of Cue: React & Act, developed by Jaroslav Sazma ([contact](#contact)).*

**Cue: Relay & Reply sends nothing to its developer or to any third party, and it never connects to
the internet.** The app has no telemetry, no analytics, no ads, no crash reporting and no accounts,
and it checks for no updates. It talks to exactly one device, the phone you pair with it, directly
over your local network and over Bluetooth, end-to-end encrypted; nothing passes through a server.
Everything it handles stays on your phone and your Mac.

## What crosses between the phone and the Mac

From the phone, the Mac receives the notifications the phone lets through — the app's name, package
name and icon, the title and text, the time, the conversation it belongs to and whether it can be
answered — and the moment each one goes away; text you send with *Send to Mac*; whether the phone
takes text copied on the Mac; whether a reply you typed reached the app; and a request to lock the
screen each time you run *Lock the Mac* on the phone.

To the phone, the Mac sends which of those notifications you closed, or clicked to open something on
the Mac; the replies you type; text you copy on the Mac, while both *Send Clipboard to Phone* on the
Mac and *Clipboard from the Mac* on the phone are on; and whether its screen is locked.

The launcher's [privacy policy](https://github.com/jaroslav-sazma/cue-launcher/blob/main/PRIVACY.md)
lists the phone's side in full under *The Mac bridge*, including which notifications never leave the
phone.

When you pair, you confirm the pairing by typing the six-digit code the phone shows into the Mac.
From then on every connection is mutually authenticated and end-to-end encrypted, and the Mac
accepts no other device in the phone's place.

## Stored on your Mac

- **In the login keychain:** the Mac's own key and certificate for the bridge, and the pairing — the
  phone's certificate fingerprint, the key for Bluetooth messages and the hardware identifier of the
  Mac the pairing was made on.
- **In `~/Library/Application Support/Cue Bridge/Sequence/`:** the counters that keep each Bluetooth
  message unique. They contain no content.
- **In Notification Center:** the phone's notifications, as the app's own — the app's name, the
  title and text, the time, and the phone's identifiers of the notification and its app.
- **In `~/Library/Caches/app.cue.bridge/icons/`:** the icons of the apps whose notifications reached
  the Mac.
- **In the app's preferences (`app.cue.bridge`):** its settings, what a click on each app's
  notifications does, and the list of up to 30 phone apps whose notifications reached the Mac —
  name, package name, icon and when last seen — that *Notification Click* shows.
- **In macOS's interaction store (Siri & Suggestions):** in the distributed build, so that macOS can
  show the notifications as communication notifications, the app hands macOS, for each notification,
  the sender's name as its title shows it, the app's name, package name and icon, and the
  conversation it belongs to — never the text. macOS keeps this on the Mac.

Copied text is never stored: the app holds it only for the moment it passes. A reply waits in memory
until the phone answers it, for half a minute at most, and a closing that has not reached the phone
yet waits in memory for up to a day.

## Logs

The app logs its work to the macOS system log under `app.cue.bridge`. The content of notifications,
replies and copied text appears only in debug-level messages, which macOS does not keep by default,
and is marked private there, so the log shows it redacted. Development builds have a debug tool that
can read the notifications on the Mac; the distributed build does not contain it.

## Your browser

A click on a notification may open a website in your browser, by your choice or the app's default
for that app; from there, the website's and the browser's own privacy policies apply. To offer
browser profiles, the app only checks which profile folders exist; it reads nothing of the browser's
data.

## Retention and deletion

*Unpair* in the app's menu deletes the pairing and its counters, every one of the phone's
notifications in Notification Center, the icons, the list of phone apps and everything handed to
macOS's interaction store. The Mac's own key and certificate, the settings and the click choices
stay for the next pairing.

Deleting the app does not delete what it stored. To remove everything, choose *Unpair* first, quit
the app and delete it, then delete the keychain items `app.cue.bridge.identity` and those named
*Cue: bridge …* in Keychain Access, the folders `~/Library/Application Support/Cue Bridge` and
`~/Library/Caches/app.cue.bridge`, and the file `~/Library/Preferences/app.cue.bridge.plist`.

## Contact

Cue: Relay & Reply is developed by Jaroslav Sazma. Questions about this policy: apps@sazmovi.cz. To
report a security issue, see [SECURITY.md](SECURITY.md).
