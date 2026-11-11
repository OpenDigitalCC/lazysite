---
id: SM1430
title: "SM1430: a public page clears the signed-in marker a dead session left"
subtitle: "After Require sign-in again on a local session, public pages still drew Sign out from the display marker while the manager answered 401."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "edge site agent, 0.16.10 test plan (O-1)"
area: auth
status-note: "SHIPPED (0.16.11): a page response to a request carrying lzs_session and no signed-in identity clears the marker through session_marker_clear_header and is not stored. A stale provider session keeps it for its renewal. t/integration/720 fails without it."
---

# What happened

"Require sign-in again" on a local session signs that session out (ruling 219). The
browser kept the display-only `lzs_session` marker (SM099), and the page's auth-sync
script draws "Sign out" from the marker alone. So public pages said "Sign out" while the
manager API answered 401. Only a visit to /manager/ cleared the marker, through the
/login bounce. A revoked session and an account since removed did the same.

# What changed

`output_page`, which every page response passes through, clears the marker when the
request carries it and has no signed-in identity. On plain CGI the identity is the auth
wrapper's verified session; in the pool it is the front door's held value; a listed
proxy's user also counts. The header comes from
`Lazysite::Auth::Session::session_marker_clear_header`, the clearing twin of
`session_marker_header`. `session_clear_headers` now uses it too.

- That one response is sent `Cache-Control: no-store, private`.
- A visitor without the marker gets no Set-Cookie, and a cached public page keeps its
  own Cache-Control.
- The HttpOnly session cookie is left alone, as /login's session check leaves it.
- A provider session refused only as stale (SM1381) keeps its marker. Its renewal sets
  the marker again (SM1425).

The marker carries no authority. This changes what the page shows, not who is signed in.

# Tests

- t/integration/720 covers both paths, plain CGI through the wrapper and the pool's
  worker. A revoked session, an unknown account and a marker with no session each clear
  the marker on the public page. A live session keeps it. No cookies, and a revoked
  cookie without the marker, get no Set-Cookie and keep `public, max-age`, on a fresh
  render and on a cache hit. It fails with the change reverted.
- t/unit/odoo/135 has a new subtest: a stale Odoo session keeps its marker on a public
  page, and once Odoo has ended the session the page clears it.
