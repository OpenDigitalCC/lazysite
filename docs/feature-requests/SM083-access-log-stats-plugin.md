---
title: "SM083 - Access-log stats plugin (modern awstats/webalizer)"
subtitle: "Turn the web server access log into on-site visitor stats"
brand: plain
---

::: widebox
Split out of the audit-trail rework (2026-06-25): the audit log records **material
actions** only (auth connected, user added, file deleted), NOT browsing. Visitor
analytics belong in a separate, opt-in plugin that reads the **web server access
log** - not the audit trail.
:::

## Idea

A plugin (the plugin system already exists - `plugins/`, the control-API
`plugin-*` actions) that:

- Takes a configurable **access-log location** (the vhost's access log; on Hestia
  typically `/var/log/.../<domain>.log`, combined format). Default to the site's
  own log; let the operator override the path.
- Parses it (combined/common log format) and draws **stats** - hits, unique
  visitors, top pages, referrers, user agents, status codes, bytes, over
  day/week/month - a modern awstats/webalizer.
- Surfaces a small dashboard in the manager (its own page/section), and/or writes
  a periodic static report page.

## Notes / open questions

- Read-only and out of band - it never writes content; it only reads the access
  log and renders stats. No overlap with the audit trail.
- Log access: the CGI user may not be able to read `/var/log` without help. May
  need a Hestia hook to expose or copy the log into the docroot's `lazysite/logs`
  area, or a cron that rolls a parsed summary the plugin can read.
- Privacy: IP truncation / anonymisation option; honour any retention policy.
- Incremental parsing (remember the last offset) so big logs aren't re-read.
- Bot filtering; GeoIP optional.

## Status

Queued. Depends on nothing already shipped; complements the audit trail (which is
now material-events-only). Good first real consumer of the plugin API beyond the
bundled examples.
