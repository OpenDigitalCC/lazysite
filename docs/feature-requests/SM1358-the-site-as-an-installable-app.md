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
- **The service worker:**
  - caches only the manager's shell, never content or anything signed-in;
  - queues uploads made while offline and sends them when there is signal.
- **The camera:** an upload control asking for the rear camera. This also works without installing.
- **Security:**
  - the worker's scope is the manager only;
  - the manifest and worker are served with the site's security headers;
  - no third-party code.

# Questions for ruling

1. Should the public site be installable too, for visitors, or only the manager?
