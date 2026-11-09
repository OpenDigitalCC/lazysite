---
id: SM1363
title: "SM1363: notices by more than email"
subtitle: "An owner may prefer a text message or a notification on the installed app to an email. Notices (a form submission, a client room message, a preview waiting) go by the routes each account chooses."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: notify
status-note: "SHIPPED (PENDING, 0.16.9) on n784 with rulings 187 and 188: webpush and webhook in Notify's route table, notify_routes beside notify_email, app notices turned on per device on /account, an empty VAPID-signed push, SMS through a webhook connector, a webhook bound beside the mail bound, a log line per attempt."
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

# Built (0.16.9, n784)

- **Routes:** `webpush` and `webhook` join `bell`, `xmpp` and `email` in `route.<type>` (notify.conf). The webhook route is the connector `webhook.connector` names (scheduled mode), so it has the connector's secret header, rate cap, refusal of redirects and call record. Ruling 188: a text message goes this way, to the operator's gateway; the engine names no provider and has no SMS hook kind.
- **Per account:** `notify_routes` (webpush, webhook) beside `notify_email`. A device turning notices on or off on `/account` adds or removes `webpush`; `webhook` is the operator's to set, since it may cost money. Per kind of notice is the site's `route.<type>`; the account chooses the route, not the kind.
- **Content:** none on any route. A push has no payload (so no RFC 8291 encryption, only VAPID signing, ruling 187); the worker says something is waiting and opens `/account`. A webhook carries the kind, title, account and link.
- **Limits:** `mail.per_hour` (default 60) counts every route's sends but webhook's (ruling 199); `webhook.per_hour` (default 20) bounds the webhook route alone (ruling 195); every attempt is a log line with its outcome. A device whose push service answers 404 or 410 is removed (ruling 199).
- **Keys:** the VAPID key at `lazysite/auth/webpush-vapid.pem`, made on first use.
- **Question 1:** answered by ruling 188: chosen per deployment, through a webhook connector, with none shipped.
