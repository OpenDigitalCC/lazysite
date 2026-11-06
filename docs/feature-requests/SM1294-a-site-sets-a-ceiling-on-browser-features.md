---
id: SM1294
title: "SM1294: a site may set a ceiling on the browser features its pages ask for"
subtitle: "permissions_policy_allow in lazysite.conf is optional. Absent, a page asks for any denied feature as SM1266 made it. Present, only a listed feature can be asked for: an unlisted one keeps the default =(), and the validator warns naming the setting. payment and browsing-topics can never be listed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 29 (2026-10-23); the site half of SM710 and ruling 2"
area: security
status-note: "SHIPPED (0.16.3) on n736: Lazysite::SecurityHeaders::permissions_ceiling and its processor copy _pp_ceiling (t/lint/55), Lazysite::Validate (the warning, page_status and the editor), config-read/config-set and the Config page, lazysite check, the configuration and front-matter docs. t/unit/processor/170, t/unit/manager/410, t/lint/55."
---

# What was asked

Ruling 29 (2026-10-23): "The per-site Permissions-Policy list is an optional ceiling:
absent, pages may ask as today; present, only listed features can be asked for (others
get the default header and a validator warning)." It is the half of [[SM710]] that
ruling 2 left for later, after [[SM1266]] built the page half.

# What shipped

- **The key.** `permissions_policy_allow` in lazysite.conf: feature names, comma or
  space separated, read case-blind. Absent or empty: no ceiling, and a page may ask for
  any of `@PAGE_FEATURES` as before. A list: a page's `<feature>: self` grants only a
  listed feature; an unlisted one stays `=()`, the value it has when nobody asks, while
  a listed one on the same page is still `(self)`. `none` lists nothing, so no page may
  ask.
- **It only ever narrows.** The list is intersected with `@PAGE_FEATURES`, so
  `payment` and `browsing-topics` (rulings 15 and 16) or a typo written by hand grant
  nothing. config-set refuses them (below) and `lazysite check` names them.
- **Both copies.** `Lazysite::SecurityHeaders::permissions_ceiling` reads the value
  and `security_headers(permissions_ceiling => ...)` applies it; the processor's marked
  copy is `_pp_ceiling` (lazysite-processor/output.pm, ADR 0001), read per response
  from the site's lazysite.conf. t/lint/55 holds the two to one answer for ten
  spellings of the key and five page asks.
- **The validator.** A page asking for a feature the site does not list gets the
  warning `permission-above-site-ceiling`, naming the key and what it lists: "'geolocation:
  self' grants nothing on this site: lazysite.conf's permissions_policy_allow lists only
  camera, so the page keeps geolocation=(). Add geolocation to permissions_policy_allow
  (Config, Browser features) to let a page ask for it". A warning, so a save is never
  refused for it (ruling 11's rule). In `validate_page`, `lazysite validate --docroot`
  and the editor's status bar. `page_status`'s `permissions` (and the camera's own
  fields) and the editor's `permissions` now show what the response sends, inside the
  ceiling.
- **The setting.** On the Config page under Browser features; config-read surfaces it
  and config-set stores it, lower case, comma separated, each name once. config-set
  refuses `payment` ("payment: is the paid-page key"), `browsing-topics` ("lazysite
  installs no trackers") and any other name that is no askable feature, naming it and
  listing what can be listed, and writes nothing. Empty clears it.
- **`lazysite check`** names each entry no page can ask for, with its line (WARN), and
  says what the list allows when it is clean.

# Per site, not per domain

The ceiling is the site's, one lazysite.conf for every domain it serves, and
`alias.<host>.permissions_policy_allow` is not an override key. That follows how the
site's other security settings are scoped: `csp` (the CSP mode) and every `auth_*`
key are read from the site's lazysite.conf only, and the domain-alias rules say why
- the Host header that selects a domain's overrides is request-supplied, so a security
setting must never vary by host. (The CSP allow-lists are per domain, but they say
which hosts a domain's own content loads from, which is presentation; a ceiling is a
restriction, and a request choosing its Host should not choose a wider one.) config-set
is already refused to a domain-confined caller (t/lint/218), so a partner scoped to one
domain cannot set it for all. SM710's per-instance concern is met by the page half:
the ceiling only bounds what pages ask for, and no page is relaxed by it.

# Tests

- t/unit/processor/170 (new): on the wire through the processor, over https: absent,
  empty and blank change nothing; `camera` keeps a page's geolocation `=()` and its
  camera `(self)`; any case; `none`; a list of only unaskable names; a domain alias line
  is not read; validate_content's warning and `lazysite validate`; page status's
  reader; `lazysite check`. Sabotage: the processor ignoring the ceiling fails three
  subtests and t/lint/55; the validator not warning fails three.
- t/unit/manager/410 (new): config-read, config-set storing and tidying, `none`, the
  refusals by name with nothing written, clearing, the Config page field. Sabotage:
  config-set without the key fails three subtests.
- t/lint/55, new subtest: the module and the processor read the same ceiling and send
  the same lines for every case.
