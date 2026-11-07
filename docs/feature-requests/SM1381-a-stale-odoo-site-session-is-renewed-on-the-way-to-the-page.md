---
id: SM1381
title: "SM1381: a site session that is only stale is renewed on the way to the page"
subtitle: "A person signed in through Odoo and idle past odoo_identity_ttl was sent to /login by every protected page, and told signed out by /login itself, while their Odoo session was still good: only the Odoo endpoint's ?csrf=1 renewed the session, and a refused page never loads it. The page gate now sends such a session through a renewal step on the Odoo endpoint, which asks Odoo once and returns the person to the page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "developer agent (0.16.7 brief, n762)"
area: odoo
status-note: "SHIPPED (PENDING) on n762: the odoo-stale verdict names the renewal path; the page gate and ?action=session send the visitor to ?renew=1 on the Odoo endpoint, which renews once and returns them, or sends them to /login with next. Loop guard lzs_renewed. Register entry drafted. t/unit/odoo/135, t/unit/auth/74."
---

# What happened

A site session the Odoo sign-in mints (SM1160) is good for `odoo_identity_ttl` after
Odoo was last asked. Past it the verifier refuses it as `odoo-stale`: it grants
nothing until Odoo says again that the person is signed in. Only the Odoo endpoint's
`?csrf=1` asked (`_site_state` in `lazysite-odoo.pl`), because only that endpoint
receives the person's Odoo session: its cookie is scoped to the endpoint's path.

A protected page does not load the endpoint. Its gate (`check_auth`, through
`request_session`) met `odoo-stale`, saw nobody signed in and sent the visitor to
`/login`. There `?action=session` answered `signed_in: false` (SM1322), so the page
showed the sign-in to a person whose Odoo session was still good. The reason was
logged at DEBUG only.

# What changes

The verdict
: The `odoo-stale` refusal carries the path where the session is renewed (`renew`),
  given by the extension (`Lazysite::Odoo::SiteSignin::renew_path`,
  `/cgi-bin/lazysite-odoo.pl?renew=1`). Core's gate and auth CGI read a generic
  `renew` from the verdict and name no endpoint of their own, so lint 321's
  allow-list does not grow.

The page gate
: A protected page that meets a refusal with a `renew` path redirects to it, with
  `next` (`?renew=1&next=/path`), instead of to the sign-in. It makes no call to Odoo
  and grants nothing. It logs the refusal at INFO with the verdict. In the pool the
  front door's verdict is used; under the plain-CGI wrapper the gate asks the verifier
  again, on this refusal path only.

The renewal step
: `GET /cgi-bin/lazysite-odoo.pl?renew=1&next=/path` runs the renewal `?csrf=1` runs,
  once. Renewed: `303` to `next`. If Odoo has ended the session, both sessions end, as on
  `?csrf=1`, and the step sends the person to `/login?next=/path`. It does the same if
  Odoo could not be asked. A session that is not stale goes back to the page without
  asking anything. `next` is a same-site path by the sign-in's own rule
  (`sanitise_next`). The step takes GET only.

?action=session
: A stale session is not answered `signed_in: false`. The auth CGI redirects (`303`) to
  `?renew=1&answer=session`, and the step gives the same answer, `{ ok, signed_in }`,
  after renewing. If not renewed it also clears the `lzs_session` marker. The chrome's
  same-origin fetch follows the redirect with its cookies.

Nothing ended without the Odoo cookie
: Only a request that carries the Odoo session cookie is renewed or can end the
  session. A cross-site request does not carry it (SameSite=Strict), so it cannot sign
  anybody out. Without the cookie the person is sent to sign in and the stale session
  is left as it was.

# The loop guard

Every answer of the renewal step sets `lzs_renewed=1` (path `/`, 60 seconds,
HttpOnly). A page gate that meets a renewable refusal while that cookie is held sends
the visitor to the sign-in instead, and logs that at INFO. So a renewal that does not
take (Odoo unreachable, a clock out of step) ends at the sign-in, never in a loop: at
most one renewal round trip a minute per browser. `?action=session` cannot loop: the
step answers it directly and redirects nowhere.

# Tests

`t/unit/odoo/135` covers these cases through the real wrapper and processor, the real
Odoo endpoint and OOM's session transport:

- a stale session on a protected page goes through the step and back to the page, which
  is served;
- a session Odoo has ended goes on to `/login` with `next` kept;
- `?action=session` renews through the step;
- the loop guard sends the visitor to the sign-in;
- without the Odoo cookie nothing is ended;
- a foreign `next` goes to `/`;
- the step is GET only.

`t/unit/auth/74` now expects the redirect for a stale session, and `t/integration/293`
holds the pool's worker to the same redirect and guard. Each test fails with
its change reverted.

# ADR 0007

The new-external-interface trigger fires: `?renew=1` is a new action on a public
endpoint. Without a token, a request can cause one Odoo call and the renewal or end of
a session. The register entry in `docs/SECURITY.md` is the trigger's assessment,
drafted for the release manager's confirmation. No sign-in method is added: renewal is
the existing `?csrf=1` renewal, reached from a new place. No dependency is added, and
no restricted data is processed in a new way.
