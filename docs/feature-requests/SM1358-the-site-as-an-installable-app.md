---
id: SM1358
title: "SM1358: the site as an installable app on a phone"
subtitle: "An owner adds their own site to their phone's home screen. Opening it lands on the simple manager, signed in by passkey, with the camera one tap away."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: platform
status-note: "Filed 2026-11-06 under SM1350."
---

# Proposed

- **Engine-shipped shell:** a web app manifest (name, icons from the site's theme, start URL `/manager/`) and a service worker. The engine ships them, so every layout gets them with no layout change. A site may turn them off.
- **The service worker works offline:**
  - it caches the manager's shell;
  - for the signed-in owner only, it keeps that site's own switchable rows, schedule and events, so the app opens without signal and shows them as last seen;
  - changes made offline (availability switches, hours, events, photos) are queued on the device, marked as waiting, and sent in the order made when there is signal;
  - each queued change carries the version it was made against. If the row changed elsewhere meanwhile, the app shows both versions and the owner chooses; nothing is overwritten silently;
  - previews (SM1354) and the client room (SM1360) are fetched when online, never served from the cache;
  - the device cache is cleared on sign-out and when the account loses access.
- **A dedicated device:** a site may enrol a tablet as a kept-signed-in device for its owner group (for example a bar tablet with its own data SIM). It is listed and revocable on the account page like a passkey.
- **The camera:** an upload control asking for the rear camera. This also works without installing.
- **Security:**
  - the worker's scope is the manager only;
  - the manifest and worker are served with the site's security headers;
  - no third-party code.

# Questions for ruling

1. Should the public site be installable too, for visitors, or only the manager?
