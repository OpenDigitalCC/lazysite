---
title: "Reported issues"
subtitle: "Externally reported defects: validation status and disposition"
brand: plain
---

Issues reported from outside the dev loop (users, partner agents), each
validated before being recorded here. An entry stays until its fix ships,
then moves to the CHANGELOG entry that closed it.

## RI-001 - dev server emits only one Set-Cookie header (auth cookie dropped)

Reported
: 2026-07-02, by a user's agent, against a pristine re-clone. Not filed
  anywhere upstream; recorded here only.

Status
: **Fixed** 2026-07-02 (committed to `claude/appearance-layouts`, ships in the
  next release). Validated 2026-07-02 (code inspection + live reproduction at
  v0.5.36); fix deferred until the eight-dimension non-functional work
  completed, then addressed. `parse_cgi_headers` now returns an ordered list of
  [name, value] pairs and the emit loop forwards every one, so repeated headers
  survive; regression test `t/unit/tools/01-dev-server-headers.t` covers the
  two-cookie login and logout cases. The dev server also gained a modulino
  `caller` guard so the pure parser is unit-testable without binding a port.

Component
: `tools/lazysite-server.pl` (dev server) - production Apache/nginx is NOT
  affected (real web servers emit repeated Set-Cookie headers correctly).

Defect
: the dev server parses CGI response headers into a hash keyed by header
  name (`%extra_headers`; `$extra_headers{$1} = $2` in the parse loop around
  `tools/lazysite-server.pl:523-536`) and emits one value per key
  (`:568-570`). `lazysite-auth.pl` emits TWO `Set-Cookie` headers on login
  (`lazysite-auth.pl:273` the real HttpOnly session cookie, `:277` the SM099
  `lzs_session=1` display marker) - the marker overwrites the real cookie in
  the hash, so the browser never receives the session. Logout (`:313-314`)
  has the same shape with the nastier consequence that the REAL cookie's
  clearing header is the one dropped, so "logout" leaves a valid session
  cookie in the browser (dev server only).

Reproduction
: seed a docroot + user, run `tools/lazysite-server.pl --port N --docroot D
  --no-seed`, POST `username=...&password=...` to
  `/cgi-bin/lazysite-auth.pl?action=login`; the response carries only
  `Set-Cookie: lzs_session=1...` - the `lazysite_auth` cookie is absent.
  Reproduced on 2026-07-02 at v0.5.36 exactly this way.

Impact
: interactive login through the dev server cannot establish a session, and
  dev-server logout does not clear one. Unnoticed until now because
  production traffic goes through Apache/nginx; but the dev server seeds
  auth users and wires the auth wrapper, so login is clearly intended to
  work there - a real regression, not a misuse.

Fix sketch
: collect response headers as an ordered LIST of [name, value] pairs (or a
  hash of arrays) instead of a flat hash, and emit every pair. While there,
  drop the `sort keys` emission (header order should follow the CGI). A
  regression test can drive the parse/emit path with a two-Set-Cookie
  fixture; a journey test could cover dev-server login end to end.

## RI-002 - WebDAV denials give no reason (partner agents retry blindly)

Reported
: 2026-07-02, by the operator relaying partner-agent experience: a connecting
  agent spent a long time discovering by trial and error that it installs
  themes over WebDAV, because the push failed without saying why.

Status
: **Fixed** 2026-07-02 (committed to `claude/appearance-layouts`, ships in the
  next release). Validated the same day by code inspection and a live
  reproduction with the DAV test harness.

Component
: `lazysite-dav.pl` - the authorisation layer (`authorise` / `authorise_layout`)
  and the request dispatcher.

Defect
: `authorise`/`authorise_layout` returned a bare numeric `403` and the
  dispatcher emitted a generic `Forbidden\n` body with no detail. A partner
  refused for a missing capability (e.g. installing a theme without
  `manage_themes`), for using the wrong path (theme files must live under
  `lazysite/layouts/<layout>/themes/<theme>/`), or for touching the active
  theme/layout (read-only over WebDAV) received the same opaque `Forbidden`
  in every case - nothing to act on, so the only recourse was trial and error.

Reproduction
: with the DAV harness, a default content partner (`manage_content` but not
  `manage_themes`) PUTs to `/lazysite/layouts/base/themes/mytheme/theme.css`;
  the response was `403` with body `Forbidden` and no capability hint.
  Reproduced 2026-07-02.

Fix
: a `_deny($code, $reason)` helper records a human-readable reason on the
  package-scoped `$DENY_REASON`; each capability/path/active-pointer denial now
  names what is missing. The dispatcher surfaces it as `Forbidden: <reason>` in
  the body and a machine-parseable `X-Lazysite-Deny-Reason` header, and logs the
  reason. Authorisation logic is unchanged - only the messaging. Regression test
  `t/unit/dav/22-deny-reason.t` covers the theme-capability, content-capability
  and active-theme cases plus the permitted-write (no-reason) path. The broader
  discoverability asks (a machine-parseable capability map, quickstarts) are
  recorded in `docs/feature-requests/BACKLOG.md`.
