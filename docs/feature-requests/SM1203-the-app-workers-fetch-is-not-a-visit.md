---
id: SM1203
title: "SM1203: the app worker's fetch is not a visit"
subtitle: "The service worker's own re-fetch of an offline page says X-Lazysite-App: keep, and the visitor log counts it apart from the visits."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: the release manager (follow-up to SM1197)
area: front end
status-note: "SHIPPED (PENDING) on n692: lazysite-processor/app.pm (refreshPage), lazysite-processor/access-log.pm, plugins/stats.pl, starter/docs/app.md; t/integration/299, t/unit/plugins/50, t/unit/processor/145."
---

# What happened

SM1197 made the installed app's service worker keep each page in
`app_offline_pages`: behind every view of such a page it fetches the page again,
without credentials, and it does the same for each at install. That second request
reached the engine like a page view. The first-party access log
(`lazysite-processor/access-log.pm`, `_access_record`) wrote it as a line on the
`page` channel with the browser's own User-Agent, and the visitor analysis
(`plugins/stats.pl`, `classify`) puts a browser User-Agent that matches no bot
pattern in `unattributed`, the class where the human visitors are. So each page
the app keeps counted twice: once for the person and once for the worker.

The release manager ruled on 2026-10-20: "do the visitor-log follow-up in 0.15.13".

# What shipped

- The worker's keeping fetch (`refreshPage` in the generated worker, used behind
  every view and at install) sends `X-Lazysite-App: keep`. A page script cannot set
  `Sec-*` headers, so the name follows the engine's other `X-Lazysite-*` headers.
  The person's own navigation is the browser's and never carries it.
- The access recorder puts a page request that carries `X-Lazysite-App: keep` on
  its own channel, `app`, the way a registry fetch is put on `registry` (SM389):
  recorded, not dropped, and not a page. Everything else is the same: the rendered
  page, the cache key and the cached copy (the header is never read by the page,
  the cache or the access decisions), the status and the response headers.
- The stats plugin counts that channel in the day rollup as `app_hits` and
  `app_by` (which page, up to 32), beside `pageviews` and never inside it or the
  visitors. Before this, a channel it did not know was left out of every figure,
  so recording alone would have hidden the traffic.
- `starter/docs/app.md` says the keeping fetch is recorded as the app's and not as
  a visitor, and `starter/docs/ai-briefing-stats.md` lists the two fields.

# Left as it is

A visitor who sends `X-Lazysite-App: keep` themselves only hides their own hit
from the visitor count: the request is still recorded, as `app`, and served as any
other. That is acceptable, since the header gives no access and changes no page.
