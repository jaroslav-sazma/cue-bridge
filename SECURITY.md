# Security policy

## Reporting a vulnerability

Report privately through GitHub's **Security → Report a vulnerability** on this repository, which
opens a private advisory only the maintainer can see. If that is not available to you, email
apps@sazmovi.cz instead. Please do not open a public issue for a vulnerability.

Useful in a report: the app's version (**About Cue:** in its menu), the macOS version, and the
shortest sequence of steps that shows the problem. A proof of concept is welcome but not required —
a clear description of the mechanism is enough to start.

Cue: Relay & Reply is a one-person project maintained in spare time, with no security team behind
it. Reports are handled on a best-effort basis: there is no promised response time, no paid bounty
and no guaranteed patch window. A fix lands as soon as the maintainer can make one, and the advisory
is published once it ships.

Supported: the latest release. Older versions receive no fixes.

## What the app is, in security terms

Cue: Relay & Reply is the Mac half of the bridge of Cue: React & Act. It has no accounts, no server
of its own and no analytics, and it opens no connection to the internet. It talks only to the one
phone the user paired with it: over the local network and over Bluetooth, mutually authenticated and
end-to-end encrypted, with keys that never leave the two devices.

Where to read more:

- the protocol — pairing, certificate pinning, the frame and record crypto, the replay window and
  what crosses in each direction — is specified in the launcher's
  [`docs/bridge-protocol.md`][protocol];
- the threat model of the bridge as a whole is in the launcher's [`SECURITY.md`][threat-model], and
  the review of the protocol and the phone's half in its [`docs/security-audit.md`][audit];
- the Mac's own side — what it stores, how it is signed, whom it trusts and the risks that remain —
  is in this repository's [`docs/security.md`](docs/security.md).

[protocol]: https://github.com/jaroslav-sazma/cue-launcher/blob/main/docs/bridge-protocol.md
[threat-model]: https://github.com/jaroslav-sazma/cue-launcher/blob/main/SECURITY.md
[audit]: https://github.com/jaroslav-sazma/cue-launcher/blob/main/docs/security-audit.md
