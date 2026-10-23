---
id: SM1299
title: "SM1299: the Odoo sign-in page returns the visitor where they were going, and /login offers it"
subtitle: "Rulings 37-39 on SM1295's questions: /odoo-signin follows ?next= after sign-in, same-site only (through the check /login's return uses, now one function); /login on an opted-in site shows a Sign in with Odoo link carrying next; and /odoo-signin is reachable during maintenance, as /login is."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, rulings 36-39 (2026-10-23), on SM1295's open questions"
area: auth
status-note: "SHIPPED (PENDING) on n736: Lazysite::Util::sanitise_next (moved from lazysite-auth.pl), the Odoo endpoint's sign-in answers (_next), lazysite-odoo.js (data-ls-odoo-next), the odoo-signin component, the system login page, Lazysite::Maintenance::exempt. t/unit/odoo/63, 120, t/unit/processor/171, t/unit/auth/02."
---

# The rulings

The release manager, 2026-10-23 (tmp/rulings-2026-10-22.md):

- **36:** the identity provider is SM1160's Odoo site sign-in, and the page is
  `/odoo-signin`, as [[SM1295]] built it. No change.
- **37:** `/odoo-signin` follows `?next=` after sign-in, same-site only (a path on this
  site, beginning with a single `/`, with no scheme, no host, no `//` and no backslash);
  anything else goes to `/`.
- **38:** on a site opted in to Odoo sign-in, `/login` shows a "Sign in with Odoo" link
  to `/odoo-signin`, carrying any `next`; the local form stays.
- **39:** `/odoo-signin` is reachable during maintenance, like `/login`.

# What shipped

- **One check for both returns.** `/login`'s return was `sanitise_next` in
  lazysite-auth.pl. It moved, unchanged but for one rule, to
  `Lazysite::Util::sanitise_next`; lazysite-auth.pl calls it, and so does the Odoo
  endpoint. The rule added is ruling 37's "no `//`": a `//` anywhere (`/a//b`) is `/`
  now, for `/login` too, where before only a leading one was. A path is otherwise
  exactly what `/login` accepted: a single leading `/` and word characters, `/`, `.` and
  `-`, so no scheme, host, query or backslash.
- **The endpoint decides, the page follows.** The sign-in page's button carries
  `data-ls-odoo-next`. lazysite-odoo.js then sends the page's own `?next=` (decoded, or
  empty) with the sign-in and with the two-factor code step; the endpoint's successful
  sign-in answers `next`, the path to go to, through `sanitise_next` (`/` for anything
  else); and the script goes there. It never goes to what it read itself, and sends and
  follows nothing for a sign-in button without the attribute or a request without `next`,
  so every other page is as it was.
- **`/login`'s link.** On a site whose sign-in is the Odoo login (the same test as the
  banner, `odoo_signin_banner`), the system login page shows "Sign in with Odoo" after the
  local form, linking `/odoo-signin`, with `?next=` carried (URI-encoded) when the visitor
  arrived with one. Shown to a signed-out visitor, as the form is; no inline style. On any
  other site it is not there.
- **Maintenance.** `Lazysite::Maintenance::exempt` lists `/odoo-signin` with `/login`,
  `/logout`, `/forgot` and `/claim`. The Odoo endpoint and the helper script were already
  reachable (a CGI path and a `.js`).
- Docs: starter/docs/odoo.md.

# Tests

- t/unit/odoo/63, new subtest, through the real endpoint: thirteen `next` values - two
  paths, empty, an https URL, `//host`, `///host`, `/\host`, `\\host`, `javascript:`, a
  bare host, `/a//b`, a query, an encoded `//` - each answered the path or `/`; no `next`
  sent, none answered; two-factor: the password step answers none, the code step answers
  the path. With the old lazysite-odoo.pl the subtest fails; without the new `//` rule in
  Util it fails on `/a//b`.
- t/unit/odoo/120 (new), the page's script under node (t/lib/odoo-next-harness.js): the
  page's `?next=` is sent decoded (found among other parameters, `+` as a space); the page
  goes to the endpoint's answer and not to what it read; no answer, no move; an unmarked
  button sends no `next` and goes nowhere; the two-factor code step carries it. With the
  old lazysite-odoo.js twelve assertions fail.
- t/unit/processor/171, two new subtests: `/login` on an opted-in site carries the link
  (with and without `next`, a `next` with query characters encoded inside the href) and
  the local form, with no inline style, and not on a site that is not opted in; under
  `maintenance: on` a page is redirected and `/odoo-signin` is served. With the old
  login.md or the old Maintenance.pm the matching subtest fails.
- t/unit/auth/02 now tests the real `sanitise_next` (it held a copy that had to mirror the
  script's), with `/a//b` added.
