---
id: SM1102
title: "SM1102: the site has one address - base_url is removed"
subtitle: "notify.conf's base_url, a second place for the site's own address, is no longer read; links in notices use site_url, which the Config page can now pin."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: notifications
status-note: "SHIPPED on n611: lib/Lazysite/Notify.pm, lib/Lazysite/Outbox.pm, starter/docs/forms.md, docs/FEATURES.md; t/unit/lib/25, t/unit/notify/03."
---

# What happened

The release manager, 2026-10-16: "so if base_url isnt required, remove it, as
the test agent asked me to configure it."

`base_url` in `lazysite/notify.conf` overrode `site_url` for the links a
notice carries. A ruling of 2026-09-30 had already made `site_url` the single
source of truth, because "a second place to write the site's own address goes
stale in silence", and kept `base_url` only as an escape for a site whose
notices must point elsewhere. The outbox's refusal for an unsubscribe link
with no absolute address told the operator to "set base_url in
lazysite/notify.conf (or site_url)", naming the second place first, which is
how the testing agent came to ask for it. With SM1101, `site_url` can be
pinned from the Config page, so nothing needs the override.

# What shipped

- `Lazysite::Notify` builds every link from `site_url` alone (`site_base` and
  both template `base` variables). A `base_url` line left in notify.conf is
  not an error and is not read.
- The outbox's refusal now says: set the Site URL on the Config page ("Use
  this address"), or turn unsubscribe off.
- forms.md and FEATURES.md no longer describe `base_url`.

t/unit/lib/25 pins that a `base_url` in notify.conf is not read; t/unit/notify/03
that the refusal names the Site URL, not `base_url`. Both fail on the code
before this change.
