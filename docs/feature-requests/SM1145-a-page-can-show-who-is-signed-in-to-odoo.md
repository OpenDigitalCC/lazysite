---
id: SM1145
title: "SM1145: a page shows who is signed in to Odoo without calling Odoo"
subtitle: "`?csrf=1` carries the signed-in person's display name from the identity cookie the endpoint already verifies, and the browser helper fills `data-ls-odoo-name` on load from it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the lazysite-sites agent (OOM Lab L-2, P3), accepted by the release manager 2026-10-17 ("all rulings accepted"; SM1082 Q1)
area: odoo
status-note: "SHIPPED on n641: lazysite-odoo.pl _who_is_signed_in, lib/Lazysite/Odoo/Identity.pm shown and configured_ttl, starter/assets/lazysite-odoo.js showName and who; t/unit/odoo/41, 44, 28."
---

# What happened

From the lazysite-sites agent, OOM Lab findings for the Odoo extension, 2026-10-17 (inbox/2026-10-17-oom-lab-findings-for-the-odoo-extension.md), finding L-2:

> A page cannot show who is signed in to Odoo after a reload. The identity
> cookie is HttpOnly (rightly), `?csrf=1` returns only `odoo_signed_in`, and the
> processor offers no page variable for it, so `data-ls-odoo-name` is filled only
> right after a sign-in. The lab added an operation (`lab.core.me`) and calls it
> on every page. `?csrf=1` could carry the identity's display name.

Every page view therefore paid an Odoo call only to print a name.

# What shipped

- `GET ?csrf=1` answers `identity: {name}` for a person who has an Odoo
  session and a current identity cookie. It reads the signed cookie the
  endpoint already verifies (`Lazysite::Odoo::Identity::identity_from_cookie`) and
  asks Odoo nothing. Nothing else about the person is in the answer: no language,
  zone, company or group. The cookie stays `HttpOnly`.
- The identity cookie keeps its rule, "never a login": the answer is the display name only.
- No identity is answered when the cookie is absent, ended (after `odoo_identity_ttl`),
  altered, or has no Odoo session behind it. The next call that reaches Odoo
  freshens an ended cookie (OI3, as before); `?csrf=1` does not call Odoo to do it.
- The TTL reader moved to `Identity::configured_ttl` so that `?csrf=1` can apply the
  operator's `odoo_identity_ttl` without loading the engine (SM1147);
  `Lazysite::Odoo::identity_ttl` asks it.
- The browser helper fills every `[data-ls-odoo-name]` with the name, as text, from
  the token fetch it makes at load. A page with no such element asks for nothing.
  `LazysiteOdoo.who()` resolves `{name}` or `null`. Two askers of the token
  fetch share one request.

t/unit/odoo/41 drives the real endpoint: a signed-in person is named from the
cookie with no round trip to Odoo, an absent, ended, tampered or sessionless
cookie names nobody, and nothing else of the person is in the answer.
t/unit/odoo/44 runs the helper under node.
