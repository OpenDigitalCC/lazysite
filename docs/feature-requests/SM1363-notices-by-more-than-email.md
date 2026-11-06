---
id: SM1363
title: "SM1363: notices by more than email"
subtitle: "An owner may prefer a text message or a notification on the installed app to an email. Notices (a form submission, a client room message, a preview waiting) go by the routes each account chooses."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: notify
status-note: "Filed 2026-11-06 under SM1350."
---

# Proposed

- **Routes:** a notice route is named and pluggable. The engine ships three:
  - email (today's);
  - web push to an installed app (SM1358), with the keys held under `lazysite/`;
  - an outbound webhook.

  Text message and messaging-app routes are extensions that use a provider the operator configures. The engine names no provider.
- **Per account:** each account chooses its routes per kind of notice. The default is email.
- **Content:** a notice says only that something is waiting and links to it. It never carries a submission's or message's contents, on any route.
- **Limits:** a per-site rate limit applies across routes, and every attempt is logged with its outcome.

# Questions for ruling

1. Text message provider: chosen per deployment, with none shipped?
