---
id: SM1352
title: "SM1352: passkeys"
subtitle: "An owner who updates their site from a phone a few times a month will not remember a password. A passkey on the phone signs them back in with a fingerprint or face."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: auth
status-note: "Filed 2026-11-06 under SM1350."
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
