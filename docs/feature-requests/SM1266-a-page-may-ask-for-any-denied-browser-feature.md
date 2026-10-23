---
id: SM1266
title: "SM1266: a page may ask for any denied browser feature"
subtitle: "SM1174's `camera: self` for every feature Permissions-Policy denies: `geolocation: self` makes that page alone send geolocation=(self) on https. A page that asks for nothing sends today's header."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "lazysite-sites agent for the OOM Lab, inbox/2026-10-22-site-chosen-permissions-policy-and-the-visitor-address-for-an-operation.md rows P-4 and P-6"
area: security
status-note: "SHIPPED (0.16.1) on n729 (claude/n729-a-page-can-ask-for-a-denied-browser-feature): lib/Lazysite/SecurityHeaders.pm and its processor copy, the peek, Lazysite::Validate, page_status, the editor. t/unit/processor/155, t/unit/mcp/55, t/unit/manager/400, t/lint/55."
---

# What happened

Every response sends `Permissions-Policy` with `=()` for twelve features
(`@DENIED_FEATURES` in Lazysite::SecurityHeaders). [[SM1174]] let one of them be
relaxed - a page whose front matter says `camera: self` sends `camera=(self)` on
https - and `_permissions_policy` and its processor copy hard-coded "camera, and
only camera". The comment said a general allow list was [[SM710]]'s question.

The OOM Lab's attendance app is the third driver (after the familyhq microphone
and the Expo card camera, both in SM710): its clock-in page needs the phone's
position, to send to Odoo 18's own clock route, and under `geolocation=()` the
page cannot ask for it even on https. Rows P-1 to P-3 of the report were checked
against the code and are accurate: the list, the lock in both copies, and
t/lint/55 pinning the lock.

# Ruling

Release manager, 2026-10-22 (tmp/rulings-2026-10-22.md #2): "Permissions-Policy:
a page opts in to any feature in @DENIED_FEATURES on its own (self only, https
only, front matter only), as SM1174 does for the camera. The site-level allow
list comes later."

# What shipped

- One data-driven key: `<feature>: self` in a page's front matter, for every
  feature in `@PAGE_FEATURES` (`@DENIED_FEATURES` less `payment` and
  `browsing-topics`, below) -
  `geolocation: self`, `microphone: self`, and `camera: self` as before. That page,
  over https, sends `<feature>=(self)`; every other feature stays `=()`, and so does
  every other page. Over plain http the key is ignored.
- SM1174's rules, for each feature: `self` is the one value that grants (one pair
  of quotes allowed); front matter only, so a body line grants nothing; decided per
  response from the page's own source on the fresh-render, cache-hit and ttl-hit
  paths, and the cache stores HTML and never headers, so a cached page keeps its
  own policy.
- The lock is gone from both copies. `_permissions_policy` takes the list a page
  asked for; the processor's copy (lazysite-processor/output.pm, ADR 0001) builds
  the line from `_pp_denied` and `_pp_page_may_ask`, the marked copies of the two
  lists. t/lint/55 pins the DEFAULT line as a literal (the line every response sent
  before), checks both lists agree, and compares the two copies by value for every
  feature, over http and https.
- The validator: a value other than `self` or `none`, or a key given twice, is
  `permission-unreadable` naming the feature; a `<key>: self` that is no feature a
  page can ask for (`geolocaton: self`, `fullscreen: self`, `Camera: self`) is
  `permission-unknown`, and grants nothing. That one is a WARNING and leaves the
  page valid (coordinator, 2026-10-22, after ruling 11: an unknown key warns and
  never blocks), since the key may be a site's own page variable. The camera keeps `camera-unreadable`
  and its sentence. In `validate_page` and `lazysite validate`.
- Shown in page status: MCP `page_status` answers `permissions` (the features
  allowed, in the policy's order) and `permissions_note`; the manager's file read
  and save answer `permissions` and `permission_issues`, and the editor's status
  bar shows "Allowed on this page (https only): geolocation". The camera's own
  fields (`camera`, `camera_note`, `camera_issue`) and its sentence are unchanged.
- The camera's behaviour is byte-identical: t/unit/processor/143, t/unit/mcp/33
  and t/unit/manager/364 pass unchanged.
- Docs: starter/docs/frontmatter.md and ai-connector-tools.md. The briefings are
  [[SM1267]].

# Not done

- Two features cannot be asked for, and stay denied on every page:
  - `payment` (ruling 15, 2026-10-22). `payment:` is already the paid-page access
    key ([[SM980]], `payment: required`), and its reader refuses a page that says
    `payment: self` to everyone.
  - `browsing-topics` (ruling 16, 2026-10-22). It is the Topics API, an interest
    profile of the visitor, and the no-trackers rule keeps it denied on every
    site. A page that says `browsing-topics: self` gets the `permission-unknown`
    warning, saying so, and the default header.
- The site-level ceiling ([[SM710]]'s instance key) is later, as ruled.
