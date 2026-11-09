---
id: SM1352
title: "SM1352: passkeys"
subtitle: "An owner who updates their site from a phone a few times a month will not remember a password. A passkey on the phone signs them back in with a fingerprint or face."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: auth
status-note: "SHIPPED (PENDING, 0.16.9) on n784 with ruling 187: enrol through the setup link or /account, sign in, list and remove; the operator's passkey-wipe; the group key passkey_only; attestation none, the key from getPublicKey(), an ordinary local session. Needs CryptX (libcryptx-perl, recommended)."
---

# Proposed

- **Enrolment:** an account may register one or more passkeys (WebAuthn) from its own account page. The first one can be registered from an emailed sign-in link.
- **Sign-in:** the sign-in page offers "Sign in with a passkey" whenever the browser supports one.
- **Installed app:** in the site's installed app (SM1358), a passkey signs the owner back in after the session ends.
- **Managing passkeys:** an owner can list and remove passkeys. An operator can remove all of an account's passkeys, for a lost phone, and that is audited.
- **Storage:** the public keys are stored with the account. No secrets are stored.
- **Coexistence:** passwords and emailed links remain. A site may make passkey the only method for a group.

# Questions for ruling

1. Should the emailed one-time link be the recovery route when every passkey is lost?

# Built (0.16.9, n784)

- **Enrolment:** the first passkey through the setup link (`/claim` offers "Use a passkey instead"); more on `/account` (`::: account-passkeys`), with the current password when the account has one. An account enrolled through a link has a locked credential marker, never an empty password.
- **Sign-in:** "Sign in with a passkey" on the sign-in page, for a browser that can use one. The same address limits, rate limiter and account gates as a password, then the same local session; no TOTP step after a passkey. The installed app signs in through the same page.
- **Managing:** list and remove on `/account`; the operator's `passkey-wipe` (Users, `manage_users`) removes them all, signs the account out everywhere, and is audited. A manager cannot add or remove a single passkey.
- **Storage:** `passkeys` in the account's record (id, public key, algorithm, label, dates, counter).
- **Passkey only:** the group key `passkey_only`, checked in the password branch of sign-in. With the group settings unreadable, a password sign-in fails closed except for an operator-group account, and the log and `lazysite check` name the file (ruling 197).
- **Checked:** origin, RP ID, a one-use challenge for the purpose, user presence, the signature with the stored key and algorithm (ES256, RS256, Ed25519), and a counter that moves forward. Attestation `none`; no CBOR (ruling 187).
- **Question 1:** answered by the design (simplicity-0169): the emailed one-time link is the route when every passkey is lost - it enrols a new one, or sets a password.
