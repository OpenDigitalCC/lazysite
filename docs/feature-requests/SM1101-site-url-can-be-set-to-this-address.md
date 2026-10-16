---
id: SM1101
title: "SM1101: the Site URL field offers \"Use this address\""
subtitle: "One button on the Config page fills site_url with the address the page is open at, so a notice sent outside a web request has a real address for its links."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: manager
status-note: "SHIPPED on n610: starter/manager/config.md; t/unit/manager/347. base_url (notify.conf) left as it is, pending the release manager."
---

# What happened

The release manager, 2026-10-16: "is base_url avaiabel as a config item? for
this and site_url, offer a 'set this' option, which sets it to the current
${REQUEST_SCHEME}://${SERVER_NAME}".

`site_url` is on the Config page, and its default is the template
`${REQUEST_SCHEME}://${SERVER_NAME}`. That is worked out per request, so a
notice the scheduler or the command line sends has no `SERVER_NAME`, and its
links fall back to bare paths (Notify's `_site_url`). The edge health check
prints `site_url (${REQUEST_SCHEME}://${SERVER_NAME})` for the same reason.

`base_url` is not a config item. It is a line in `lazysite/notify.conf`, the
deliberate override for a site whose notifications must point somewhere else.
A ruling of 2026-09-30 made `site_url` the single source of truth, because "a
second place to write the site's own address goes stale in silence"; with
`site_url` set, notifications use it.

# What shipped

- A config field may carry `set_current: true`. Such a text field gets a "Use
  this address" button beside it, which fills it with the page's own origin:
  the address as the visitor reached it, through any proxy, with a port only
  when it is not the default. The form is marked unsaved; Save writes it, as
  a preset does.
- `site_url` carries it, with a note saying why a pinned address matters.

t/unit/manager/347 drives the page's functions in node: one button, on the
marked field only; it fills the origin, marks the form unsaved and saves
nothing.

# Open

Whether `base_url` should become a config item, against the 2026-09-30
ruling, is the release manager's.
