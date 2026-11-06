---
id: SM1322
title: "SM1322: /login asks the server whether the session is honoured"
subtitle: "/login judged \"signed in\" from the lzs_session display marker alone, which outlives a revoked session and an Odoo session gone stale, so it told a visitor the site had just refused that they were already signed in and hid the sign-in form. The page now asks the auth CGI, and a session it no longer honours clears the marker and shows the sign-in."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 49 (tmp/rulings-2026-10-22.md), Q4 (a), on T-07 of the inbox triage (tmp/inbox-triage-2026-11-04.md): a site report (G); ruling 85 (Q17) on this branch's question"
area: auth
status-note: "SHIPPED (0.16.5) on n742: GET /cgi-bin/lazysite-auth.pl?action=session answers request_session's verdict and clears the marker on a no; lazysite-chrome.js asks it on a page carrying data-ls-auth-check, which login.md's panel does; the panel offers \"Sign in as someone else\" (?action=logout&then=signin, landing on /login with next). t/unit/auth/74."
---

# What was asked

Ruling 49 (Q4 (a)): "/login checks the session on the server; refused or stale clears
the marker and shows sign-in (T-07)."

Ruling 85 (Q17): "/login, for a valid session that cannot reach ?next=, offers \"Sign in
as someone else\" (signs out, shows the form)."

The report: `/login` said "You are already signed in" to a visitor the access rules had
just refused. "Signed in" was judged only from `lzs_session` (`lazysite-chrome.js`), the
display marker SM099 added, which is set for the full session lifetime
(`lazysite-auth.pl`, `Auth/Session.pm`). A session revoked or expired since, and an
Odoo-backed session gone `odoo-stale` after `odoo_identity_ttl` (it then holds no
groups), kept the marker, so the page drew the signed-in panel and hid the form.

# What shipped

- **`GET /cgi-bin/lazysite-auth.pl?action=session`**: `{ok: true, signed_in: true|false}`
  from `Lazysite::Auth::Session::request_session`, the verdict every surface asks, so it
  cannot disagree with the page that refused the visitor. A trusted proxy's user counts
  as signed in, as it does everywhere. The answer is `Cache-Control: no-store`, says
  nothing of why (the reason is the site log's line, from `session_log_line` as the
  wrapper logs it), and on a no clears the marker. The HttpOnly session cookie is left
  alone: the Odoo endpoint may still renew a stale Odoo session.
- **`lazysite-chrome.js`**: a page carrying `data-ls-auth-check` asks that endpoint
  when the marker is set (same origin, uncached). A no clears the marker and draws the
  controls again, so the sign-in shows. A yes, an error, no answer or no network leaves
  the page as the marker drew it. A page without the attribute, or a visitor without
  the marker, asks nothing, so no other page makes a request it did not make before.
- **`login.md`**: the "already signed in" panel carries `data-ls-auth-check`.
- **"Sign in as someone else"** (ruling 85): the panel's link is the existing sign-out,
  `?action=logout&then=signin`, with the page's `?next=` (URI-escaped). The sign-out is
  unchanged - the session is revoked and both cookies cleared - and with `then=signin`
  it lands on the sign-in page (`auth_redirect`, `/login` by default) carrying `next`
  through `sanitise_next`, so a next that is not a path on this site is dropped. A
  plain sign-out still lands on `/logout`. The sign-out takes no CSRF token, as every
  sign-out link on the site already does; the worst a forged one can do is sign
  someone out.
- `docs/auth.md` says the panel shows only while the site honours the session.

# Tests

- **t/unit/auth/74** (new), the server: a valid local session is yes, with the marker
  kept, as JSON and `no-store`; no session cookie, an expired one, a mis-signed one and
  one for an account that is not there are no, and clear the marker; the answer has
  only `ok` and `signed_in`. An Odoo session checked within `odoo_identity_ttl` is yes,
  one checked longer ago is no, clears the marker and leaves the session cookie. The
  login page's panel carries the attribute.
- The script, under node with a stand-in document and fetch
  (`t/lib/auth-check-harness.js`, as the Odoo helper's tests drive theirs): the page
  draws "signed in" from the marker, asks once (the URL, same-origin, `no-store`), and
  on a no the marker goes, nothing else in the jar does, the form shows and the panel
  does not. On a yes, a 500, a network failure and an answer without `signed_in` the
  page stays as drawn. Without the attribute, or without the marker, nothing is asked.
- Ruling 85: the panel rendered through Template Toolkit with `?next=/members` carries
  the link with `next=%2Fmembers`, and without a next carries none. That request
  through the CGI is a 302 to `/login?next=/members` clearing both cookies, and the
  session is no longer honoured after it; a next of `//evil.example/` lands on `/login`;
  a plain sign-out lands on `/logout`.

With `lazysite-auth.pl` at the base the server assertions fail (17); with
`lazysite-chrome.js` at the base the script subtest fails 8; with `login.md` at the base
the page assertion fails. With the sign-out always landing on `/logout` 2 fail; with the
panel's link removed 2 fail.

# Not done

- The panel does not say whether the session reaches `?next=`; it offers the other
  sign-in to every signed-in visitor, which covers both cases the ruling names.
- A site that keeps its own `login.md` (or a layout's) needs the attribute and the link
  added to its panel; the engine's copy has them.
- While the answer is on its way the panel shows, as the marker says; a refusal then
  swaps it for the form.
