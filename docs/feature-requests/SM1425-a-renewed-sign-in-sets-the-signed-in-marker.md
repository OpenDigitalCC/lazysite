---
id: SM1425
title: "SM1425: a renewed sign-in sets the signed-in marker again"
subtitle: "After Require sign-in again, the verifier's stale answer cleared the display marker and the renewal did not set it back, so the page showed Sign in to a person who was signed in."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "release manager, from n801's OpenID Connect proof against a real provider"
area: auth
status-note: "SHIPPED (PENDING): a successful renewal, by OpenID Connect or by the Odoo endpoint's renew, sets lzs_session again with a sign-in's attributes, through the one helper the sign-in's cookie pair uses. Tests t/unit/extensions/170 and t/unit/odoo/135 fail without it."
---

# What happened

A session marked to sign in again (ruling 214) is refused as stale. The verifier's
stale answer clears the display-only `lzs_session` marker. The renewal that followed,
through the OpenID Connect endpoint or the Odoo endpoint's renew, kept the session but
did not set the marker, so the page script showed "Sign in" to a person who was signed
in. n801 found it proving OpenID Connect against a real provider; the Odoo renewal
skipped the marker in the same way.

# What changed

`Lazysite::Auth::Session::session_marker_header` is the one place the marker's header
is written. `session_cookie_headers` (the sign-in's pair) uses it, and so do both
renewals: `lazysite-oidc.pl` sets it when the callback renewed a session in place, and
`lazysite-odoo.pl` sets it when its renew step renewed or found the session not stale.
The marker carries no authority; the HttpOnly session cookie remains the gate.

# Tests

t/unit/extensions/170 drives a renewal through a fixture provider and asserts the
response sets `lzs_session` exactly as a fresh sign-in does. t/unit/odoo/135 drives the
Odoo renew, for a page and for the session probe, with the same assertion. Both fail
with the change reverted.
