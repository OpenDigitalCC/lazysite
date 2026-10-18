---
id: SM1160
title: "SM1160: on an Odoo app site, the person's Odoo login is the site sign-in"
subtitle: "A site that opts in treats a successful Odoo sign-in (password, and the authenticator code where Odoo asks) as the site sign-in: the identity is odoo:<login>, no lazysite account is made, the groups are the mapped Odoo groups the person holds, and signing out ends both."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the OOM agent (inbox L3), at the owner's request; ruled by the release manager 2026-10-18
area: odoo
status-note: "SHIPPED on n653: SiteSignin.pm (new), Auth/Session.pm (the odoo= session and its verifier branch), Odoo.pm, lazysite-odoo.pl, lazysite-auth.pl, render.pm and the fallback layout (odoo_signin_banner), lazysite-odoo.js, plugins/odoo.pl, lazysite-check; t/unit/odoo/60, 61. Needs OOM 0.33 (SM1175). Follow-up: lazysite-layouts."
---

# What happened

The L3 filing (inbox/2026-10-17-L3-the-odoo-login-is-the-site-sign-in.md), 2026-10-17:

> Today a session binding needs the person signed in to lazysite (authenticated
> mode) and also signed in to Odoo through the extension. That is two logins. On a
> site whose users are Odoo users, the Odoo sign-in (slice B) becomes the site
> sign-in: one login, the person's Odoo login. What lazysite needs for
> authorisation (the account the capability is held by, the audit's actor) comes
> from that sign-in.

with the owner's ruling behind it: "One Odoo login per person for the Odoo activities, whichever interface is used. It should be Odoo-centric. Shared tablets are allowed. A person who shares a device while signed in stays responsible for what is done under their login." Its four questions: how an account is tied to an Odoo login; how capabilities are granted; how sign-out ends both and how an ended Odoo session ends the site session; and a short idle time-out and a visible "signed in as" for shared devices. Passkeys "later, not now".

# The rulings

The release manager, 2026-10-18:

1. **Session-only identity.** "No lazysite account is made or needed: on a site that opts in, a successful Odoo sign-in through the extension (password, plus the two-factor code where Odoo asks) is the site sign-in, and the site identity is `odoo:<login>`. Nothing to provision; a leaver disabled in Odoo cannot sign in. Opt-in per site in the Odoo extension's config (a new key, `odoo_site_signin: on`, default off; on a site without it, nothing changes)."
2. **Capabilities by mapping Odoo groups.** "The operator maps Odoo groups to lazysite groups in the extension's config (`odoo_group_map`, Odoo group xml id -> lazysite group). The person's Odoo groups are read at sign-in. MANAGER RIGHTS ARE NEVER GRANTED THIS WAY: a mapping to a group that carries any manager/operator capability is refused when the config is saved/loaded, by name. The groups feed the same ACL path page access already uses (no second ACL)."
3. **Sign-out ends both.** "Signing out of the site ends the Odoo session (sign_out through OOM) and clears the site session and identity cookie; an Odoo session that has ended (timed out, account disabled, password changed) ends the site session at the next request that learns of it, and the site session's own lifetime never outlives what the identity cookie allows without a fresh Odoo check."
4. **"Signed in as <name>"** with a sign-out link on every page of such a site: a template variable the default layouts render.
5. **Not built:** an idle time-out (not ruled in). Passkeys later.

After the first stop-and-report (the groups are not in what OOM returns at sign-in, and a person's session cannot read group xml ids), the release manager ruled further, 2026-10-18, and OOM 0.33 shipped `core.has_groups` (inbox/2026-10-18-oom-0.33-core-has-groups.md):

- **Groups.** "Ask Odoo 'has group X?' AS THE PERSON for each xml id in odoo_group_map, using OOM 0.33's `core.has_groups` ... runs on the context's own credential, no admin. Run it on the person's own session right after sign-in (and after the two-factor code) and on each refresh. An `unknown` xml id is named in lazysite check / the extension status so the operator fixes the map; it grants nothing."
- **Store.** "The mapped lazysite groups are held SERVER-SIDE in the existing session record, never in the cookie. SEC-2026-07 M5 stays true. The verifier's branch for an `odoo:` session reads the groups from that record, not from the users file and not from the cookie; the record is the authority, and a revoked/expired record ends the session. Encode the login in the payload so ':' cannot break the parse."
- **Refresh.** "The page's `?csrf=1` call re-checks with Odoo at most every odoo_identity_ttl (default 900 s): when the identity is older, it asks Odoo once (session still valid + has_groups), renews the record and the site cookie, or ends the site session if the Odoo session is gone. Keep `?csrf=1` free of Odoo calls otherwise (SM1145/SM1147)."

# What shipped

**The opt-in and the map** (`lazysite/odoo.conf`, shown on the Odoo extension's page):

- `odoo_site_signin: on` - absent or anything else is off, and an off site behaves exactly as before: no site cookie, no record, no banner (t/unit/odoo/60, first subtest).
- `odoo_group_map: sales.group_wholesale = wholesale, base.group_user = staff` - at most 50 entries (OOM's cap). Each entry's left side is an Odoo xml id (`module.name`), its right side a lazysite group name.
- **A target that carries any capability is refused, by name, at save and at load.** The test is "the group, or any group it nests, carries any capability (`ui`, `manage_users`, the `manager` flag, or any other key in the capability list)". It is "any capability" and not "a manager one" because the gates that read a request's group NAMES (the ACL operator bypass, the login landing) take capabilities from the names alone, and every capability is a door of the manager or the API. Save: `Manager::Plugins` calls the field's `validate_group_map` and answers `'odoo_group_map' is refused: 'sales.group_admin = role-opsuser' is refused: ...` with the operator on the form. Load: `SiteSignin::group_map` re-applies the test every time it is read, so a group that GAINED a capability after the map was saved stops being granted, and the map's refused entries grant nothing. The Odoo status action shows `site_signin: {enabled, mapped, refused[], unknown[]}` and `lazysite check` names each refused entry and each unknown xml id (WARN, with what to fix).

**The groups** (`Lazysite::Odoo::site_groups`): one `core.has_groups` per sign-in or refresh, on the person's own session, asking exactly the mapped xml ids - a refused entry is never asked. Odoo answers 1 or 0 for each; the held ones become the lazysite groups. An id Odoo does not know holds nothing and is written to `lazysite/odoo/unknown-groups.json` for status and `check`. Groups that cannot be read (Odoo unreachable, an OOM before 0.33) are no groups, never a guess: the person is signed in and holds only what needs no group.

**The session** (`Lazysite::Auth::Session`): minted through the session machinery, not beside it.

- *Payload.* The existing `user:ts:sid:groups` with the user field `odoo=<login>`, every byte outside `[A-Za-z0-9._@+-]` written `%XX` (so ':' and '%' in a login are carried safely), and the groups field EMPTY. The existing HMAC, the existing cookie `lazysite_auth` (HttpOnly, SameSite=Lax, Path=/, Max-Age the session lifetime, Secure over HTTPS) and the display marker `lzs_session` are used unchanged. Why it cannot collide with a local name: a local account name is `[a-zA-Z0-9_.-]` only (sign-in strips every other byte before anything is looked up), so it holds neither '=' nor ':'; a payload with '=' in its user field is never read as local, and the identity `odoo:<login>` holds a ':' no local name can. A local-shaped payload that spells `odoo:` with a colon splits wrongly and is no identity (tested).
- *Record.* A line in the existing session registry (`lazysite/auth/sessions.jsonl`, the one the Sessions page lists): `{sid, user: "odoo:<login>", t, odoo: 1, checked, name, groups, ip, ua}`. The verifier's `odoo=` branch is: signature and lifetime as for any cookie, then the opt-in is on, the site is secured, the sid is not revoked (`revoked.json`, the mechanism the wrapper's logout and the Sessions page use), the record exists AND names this user (no record, or another user's, is no session), and `checked` is within `odoo_identity_ttl`. The groups returned are the record's, less any the CURRENT map no longer grants. The users file, the groups file and the user-settings are not consulted. A renewal appends a newer line for the same sid (same `t`, so the wrapper's pruning and the Sessions page see one session; the page skips `renew` lines); the registry is append-only, so no write races the wrapper's.
- *Where it is minted.* Only inside `sign_in` (no second factor) and `sign_in_code` (after Odoo accepted the code) of the engine, where the Odoo session id is in hand. If the site session cannot be made (no auth secret, registry unwritable, an unsecured site, no login from Odoo) the Odoo session is ended and the sign-in is refused by name, so nobody is left signed in to half a login. The password step of a two-factor account mints nothing.
- *Who it is downstream.* The wrapper sets `X-Remote-User: odoo:<login>`, `X-Remote-Groups` from the verifier and, as a verifier's value, `X-Remote-Name` from the record; the one identity reader `request_identity` (source `cookie`) sees them, so the page gate (`auth: required`, `auth_groups`), per-file ACLs and the endpoint's `authenticated` mode read the same mapped groups - no second ACL. The audit actor is `odoo:<login>` (sign-in and sign-out lines, and the wrapper's own logout line). The endpoint holds an Odoo person to no capability (`caps` is `{}`).

**Sign-out and ended sessions** (rulings 3):

- The banner's sign-out (`signout`, with the visitor token as before) ends the Odoo session through OOM, revokes the site sid, clears `lazysite_auth` and `lzs_session` and the Odoo cookies (t/unit/odoo/60: Odoo's destroy is called once; the old cookie then verifies as `revoked`).
- Every way the Odoo session ends comes through the endpoint's one `_clear_cookies`, which now ends the site session too: an Odoo call answering session-ended (a session binding, the existing `_refresh_identity` path), the `?csrf=1` refresh finding it gone, and sign-out.
- The converse: an Odoo session that has NO site session behind it on a site that opted in (the site session was signed out at the wrapper's own logout, revoked from the Sessions page, or lapsed) is ended by the next `?csrf=1`. One never outlives the other.
- *The bound.* The site session grants nothing once its record's `checked` is `odoo_identity_ttl` old (60 to 86400 seconds, default 900): the same key and the same reading as the identity cookie, so the site session never outlives what the identity cookie allows without a fresh Odoo check. The wrapper reports such a session as `odoo-stale` (DEBUG) and the request is anonymous.
- *The refresh.* `GET ?csrf=1` on an opted-in site: with a stale record and an Odoo session, ask Odoo ONCE (`identity_of`, then `core.has_groups`), renew the record (and the identity cookie), or, if Odoo says the session is gone, end the site session. A fresh record costs no Odoo call (t/unit/odoo/60 counts the calls). The site cookie is not re-sent on renewal: it carries nothing that ages (no time of last check, no group), so there is nothing in it to renew; the record is what is renewed. A transient failure to ask leaves the session stale (no grant) until the next try.
- *What a person notices.* A reader idle on one page for more than `odoo_identity_ttl` who then follows a link to a restricted page is bounced to the sign-in page (the wrapper cannot ask Odoo); the next page load's `?csrf=1` renews. A site whose people read for long should raise `odoo_identity_ttl`.

**The banner** (ruling 4): the template variable `odoo_signin_banner` - the same markup for every visitor (so a cached page is never one person's), empty on any other site. The fallback layout (the engine's own) renders it in the site bar in place of the account Sign in/out links, which would not end the Odoo session. The browser helper fills the name as text and shows the signed-in part (`Signed in as <name>`, `Sign out`) or the sign-in link, from the `?csrf=1` fetch the page makes anyway (t/unit/odoo/61). The sign-in link opens the Odoo dialog, two-factor step included.

# Tests

t/unit/odoo/60 (fails on the base, passes after) drives the real endpoint, OOM's session transport and core.has_groups, the real wrapper and the real processor: opt-in off changes nothing; the map is refused at load and at save by name; sign-in gives `odoo:jane@example.com` with `staff,wholesale` (and not the refused or unknown groups), asked as uid 7 for exactly the mapped ids; the cookie carries no group and the record does; a `wholesale` page is served and a `vip` page refused; a person holding nothing is refused the first; removing a mapping drops the group before any refresh; the banner is in the default layout and absent when off; two-factor mints only after the right code; sign-out ends both; a stale record grants nothing, renews on one Odoo ask with fresh groups, and a second `?csrf=1` costs no call; an Odoo session that ended (by the refresh, by a session-binding call, or by the missing site session) ends the other; forged credentials. t/unit/odoo/61 holds the banner script (node).

Sabotage (each caught): the verifier ignoring staleness, the current map, a missing or foreign record, the opt-in, or an unsecured site; the `?csrf=1` refresh never asking Odoo; the refresh not ending the site session when Odoo has; `_clear_cookies` leaving the site session.

# Security

*Authentication change; what each credential gets, and why each protection still holds.*

**The credentials, and what a thief gets**

- *The Odoo password (and the authenticator code).* As before: a function argument to OOM and nowhere else (SM747 B, SM1157). Nothing in the new code logs, stores or echoes either. A password-guessing attack is counted by the same limiter as before (per address and per login) before Odoo is asked.
- *A stolen site cookie (`lazysite_auth`).* It is `odoo=<login>:ts:sid:` under the site's HMAC. It gets that person's site identity and the groups in the server-side record, until the first of: the record's `checked` is `odoo_identity_ttl` old and nothing renews it (a thief without the person's Odoo cookie cannot make the refresh succeed: the refresh asks Odoo with the Odoo session cookie, which is a different cookie, signed with a different secret, HttpOnly, SameSite=Strict and scoped to the endpoint path, so it is not sent to pages); the person signs out or the Odoo session ends (the sid is revoked); an operator revokes the sid from the Sessions page; `session_lifetime` (24 h by default, in the signed `ts`); or the opt-in is turned off. It holds no capability anywhere (not the manager, not the API), whatever group names the record carries, because a capability-carrying target cannot be mapped.
- *A stolen Odoo session cookie (`lzs_odoo_session`).* Unchanged: it runs that person's session bindings until Odoo or the 12-hour signature ends it. It cannot mint a site session: only the password sign-in and the code step do.
- *A forged cookie.* Without the secret: the signature fails. With a valid signature over a payload someone else could not have had made (the secret is the site's): a payload naming a sid that has no record, or a record for another user, is `no-record`; groups written into the payload are ignored (the field is not read for an `odoo=` user). Tested.
- *A forged header.* `X-Remote-User: odoo:x` / `X-Remote-Groups` sent by a client is stripped by the existing trust gates exactly as any other identity header (t/unit/odoo/60 sends one through the wrapper and the processor and opens nothing); only a trusted proxy's headers are believed, as before, and `odoo:` is no different from any other name a trusted proxy may send.
- *An expired credential.* The cookie past `session_lifetime`: `expired`. The record past `odoo_identity_ttl`: `odoo-stale`, no grant, until Odoo is asked. An Odoo session Odoo has ended (timed out, account disabled, password changed): the next refresh or session call learns it and revokes the site sid. A person disabled in Odoo cannot sign in. Between the change in Odoo and the next ask, a site session keeps what it had for at most `odoo_identity_ttl` (default 15 minutes): that is the bound the ruling asks for, stated and operator-set, not a hole.

**Why each protection still holds**

- *Cookie flags, signature and lifetime:* the session is the wrapper's own cookie, with the wrapper's attributes and the one `session_lifetime` setting; the verifier is the one chain (`verify_session_cookie`) every surface already uses, and the Odoo endpoint, the data endpoint and the form handler get the Odoo branch by calling it.
- *SEC-2026-07 M5 (groups never from the cookie):* the cookie's group field is empty and ignored; the groups are the record's, re-filtered by the current map on every request.
- *CSRF:* unchanged. The sign-in, code and sign-out POSTs need the visitor token (bound to the SameSite=Strict visitor cookie). A request carrying the identity gets the session CSRF token keyed on `odoo:<login>` from the same secret, so an authenticated-mode binding is token-checked as for any account.
- *Revocation and audit:* sign-out and every session-ending event revoke the sid in `revoked.json` (the Sessions page's mechanism, fail-closed on a broken store), and the audit trail's actor is `odoo:<login>` for sign-in and sign-out. The Sessions page lists the session and can revoke it.
- *No privilege through the door:* (a) a mapping to any capability-carrying group is refused at save and at load, by name; (b) the endpoint gives an Odoo identity no capability; (c) the wrapper marks no manager for it, and the verifier refuses the session altogether on an UNSECURED site (where "any authenticated user is a manager", SM138): the sign-in is refused there with the reason, and a session cookie is `odoo-unsecured`; (d) `odoo:<login>` cannot be a local account's name (a ':' cannot be typed in a local login), so it cannot shadow or be confused with one, and local sign-ins are untouched.
- *The Odoo side is the authority:* the groups are Odoo's own `has_group` for the signed-in user, run on their own session (no administrator right, no `ir.model.data` read, and nothing about another user can be learned); Odoo still refuses anything a binding asks that the person's Odoo rights do not allow.
- *Off means off, and ends:* with the opt-in off nothing in the new code runs on a request (the endpoint reads one config key), the banner is empty, and any `odoo=` session already issued stops verifying at once.

**Accepted and stated**

- A site session lives at most `odoo_identity_ttl` past the last time Odoo was asked (above). Idle time-out: not built, as ruled. A shared tablet shows "Signed in as" on every page; the person who leaves a device signed in stays responsible, as the owner ruled.
- The wrapper's own `?action=logout` link ends the site session only; the next `?csrf=1` then ends the Odoo session (above), but until then the Odoo session cookie exists on that browser. The default layout does not show that link on an opted-in site.
- A restricted-page bounce after more than `odoo_identity_ttl` on a single page (above).
- On a site that opts in, an Odoo session obtained before the opt-in is ended by the first `?csrf=1`; the person signs in again.

# Follow-ups

- **lazysite-layouts** (another project): its layouts need to render `[% odoo_signin_banner %]` in the header, as the fallback layout does, for a site on one of them to show "Signed in as". Without it the site works and the person has the sign-in dialog and sign-out through their own markup (`data-ls-odoo-signin`, `data-ls-odoo-signout`, `data-ls-odoo-name`). To be filed in that project's inbox by the parent.
- A login page for an opted-in site: set `auth_redirect` to a page carrying a `data-ls-odoo-signin` button (or the banner); a ready-made page is not part of this filing.
- Passkeys: later, as ruled.
