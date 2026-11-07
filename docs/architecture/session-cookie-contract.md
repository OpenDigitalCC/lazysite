---
title: "lazysite - the session cookie as an external contract"
subtitle: "The lazysite_auth format, the key it is signed with, expiry and revocation, and how an outside process on the same host verifies it read-only"
brand: plain
standard-margins: true
---

# Why this document exists

A lazysite sign-in is a signed cookie, `lazysite_auth`. Until SM1383 its format
was the engine's private business: one writer (the sign-in in
`lazysite-auth.pl`) and one verifier (`Lazysite::Auth::Session`). Ruling 132 lets
an outside process on the same host share the sign-in by verifying that cookie
itself, so the format now has a reader outside the engine.

This page is the contract that reader relies on. Every statement on it was
checked against the code, not the docs: the writer is `_mint_session` in
`lazysite-auth.pl`, and the verifier is `verify_session_cookie` in
`lib/Lazysite/Auth/Session.pm`. `t/unit/auth/75` mints a cookie through the real
sign-in, verifies it the way this page says an outside process does, and checks
that the engine's verifier agrees, the legacy variant included. A change to the
format fails that test.

**The format will not change silently.** If it must change, the change is
versioned: the verifier learns the new shape before any writer issues it, the
old shape keeps verifying until the cookies that carry it have expired, and this
page, the test and the CHANGELOG change in the same commit.

# The cookie

Name
: `lazysite_auth`.

Attributes
: `HttpOnly; SameSite=Lax; Path=/; Max-Age=<session lifetime>`, plus `Secure`
  when the sign-in was served over HTTPS.

Value
: `<payload, percent-encoded>:<signature>`. The signature is 64 lowercase hex
  characters. Every character of the payload outside `[A-Za-z0-9_.~:-]` is
  percent-encoded as `%XX`, so its colons stay literal. A verifier takes everything
  before the last `:` as the encoded payload and decodes it before checking the
  signature.

Beside it
: the sign-in also sets `lzs_session=1`, readable by page scripts so a page can
  show the right sign-in control. It carries no identity and proves nothing.

# The payload

Current shape, issued by every sign-in since SM141:

    username:timestamp:sid:groups

username
: the account name, as it appears in `lazysite/auth/users`.

timestamp
: the issue time, in whole epoch seconds.

sid
: the session id: exactly 16 lowercase hex characters (8 random bytes). It is
  the id the session registry lists and `revoked.json` revokes.

groups
: the account's groups at sign-in, comma-separated. **Informational only.** The
  engine never takes an identity's groups from the cookie (SEC-2026-07 M5): it
  resolves them fresh from `lazysite/auth/groups` on every verification, so a
  demoted account loses a group at once. An outside process must do the same.

Legacy shape, issued before SM141:

    username:timestamp:groups

It carries no sid. It stays valid until it expires naturally, and a per-user
`not_before` ends it; a sid revocation cannot reach it.

Telling them apart
: split the decoded payload on `:` into at most five fields. When there are four
  and the third is exactly 16 lowercase hex characters, it is the current shape;
  when there are five and the fourth is, it is the sliding shape below;
  otherwise it is read as legacy: the first field is the user, the second the
  timestamp, and the sid is empty. Groups contain commas, never colons.

Sliding shape, read but not yet issued (SM1390 made the reader reachable):

    username:timestamp:seen:sid:groups

`seen` is a last-seen time that will move while `timestamp` stays the issue
time; the cookie's age is counted from `seen`. Nothing issues it today; when a
writer does, this page says so. An outside process may read it as above or
refuse five fields; a five-field value it does not expect is not a current
cookie.

A payload whose first field is `v1` is not a session (SM1390, ruling 147). `v1`
is the marker of the theme-preview cookie, signed with the same key over
`v1:<expiry>:<layout>:<theme>:<user>`; without this rule a preview verified as
a legacy session for an account named `v1`. No account may be named `v1`: every
door that creates or renames one refuses the name, and `lazysite check` names
one that already exists. The preview verifier refuses the other direction by
field count: a preview has exactly five fields, a session
four or three. The CSRF token is the bare HMAC of `csrf:<user>:<hour>` and
never travels with its payload, so it cannot be presented as either.

An account name beginning `odoo=` is a session the Odoo sign-in minted (SM1160).
Its groups and freshness are in the session registry
(`lazysite/auth/sessions.jsonl`), not in any account; an outside process that
does not read that registry must refuse such a cookie.

# The key

The signature is `HMAC-SHA256(payload, key)` as lowercase hex, over the
**decoded** payload. The key is the one line of `auth/.secret` in the site's
engine tree - `<docroot>-lazysite/auth/.secret` when that tree exists, otherwise
`<docroot>/lazysite/auth/.secret` - with its newline removed. It is 64 lowercase
hex characters, and it is used **as that text**, not as the 32 bytes it spells.

The file is `0660`, shared between the site user and the web server's group,
never world-readable. The first sign-in creates it when it is absent;
verification never creates it, and a missing key means no cookie verifies.
`rotate-auth-secret` replaces it, which ends every session on the site at once.
This document never carries its value, and nothing that relies on it should.

**The key is symmetric.** Whatever can read it to verify a cookie can also mint
one, for any account on the site, the operator's included. "Read-only" is
therefore a promise about what an outside process does, not a limit on what it
could do: giving it read access to `.secret` trusts it as far as the web server
is trusted.

The same key also signs the manager's CSRF tokens and the theme-preview cookie,
over payloads of their own. An outside process uses it to verify `lazysite_auth`
and for nothing else.

# Verification, in the engine's order

1. **Shape.** The value is `<encoded payload>:<64 lowercase hex>`; anything else
   is refused.
2. **Signature.** Recompute the HMAC over the decoded payload and compare it with
   the cookie's in **constant time** (the engine's `const_eq`: equal lengths, then
   an OR of every byte's XOR). A plain string comparison leaks how much matched.
3. **Purpose.** A payload beginning `v1:` is refused: it is a preview, not a
   session (above).
4. **Not yet valid.** The timestamp (and `seen`, when present) is whole seconds
   and may not be more than **300 seconds** ahead of the verifier's clock - the
   allowance for a cookie minted on another host of the same site whose clock
   runs ahead (SM1390, ruling 147). Further ahead is refused.
5. **Expiry.** The cookie has expired when `now - seen >= lifetime`, where `seen`
   is the timestamp for the issued shapes. The lifetime is `session_lifetime:`
   in `lazysite.conf`, honoured from 300 to 31,536,000 seconds; any other value,
   or none, means 86,400 (24 hours). The browser drops the cookie at the same
   age (`Max-Age`), but the server's check is the one that counts.
6. **The account exists.** A line `username:` in `lazysite/auth/users`. A
   removed account's cookie is not an identity.
7. **Not disabled.** `lazysite/auth/user-settings.json` gives the account
   `"disabled"` true: refused.
8. **Not revoked**, by `lazysite/auth/revoked.json` (below).
9. **Groups**, fresh from `lazysite/auth/groups`: each line is
   `group: member, member`, and the account's groups are the lines that name it.

A store that exists and cannot be read or decoded is not an empty store. The
engine refuses every session while `users`, `user-settings.json` or
`revoked.json` is broken (SM1024), and an outside process must do the same:
"cannot tell" is never "nobody is revoked". An absent `revoked.json` or
`user-settings.json` is the ordinary state of a site that has never written one.

Inside a request the engine then narrows the groups by the visitor's address
(address profiles, SM1140), and a trusted proxy's user takes precedence over the
cookie (SM1130). Both are about the request rather than the cookie; an outside
process reading the groups file gets the set before that narrowing.

# revoked.json

    { "sids":       { "<sid>": <revoked at, epoch> },
      "not_before": { "<username>": <epoch> },
      "kept":       { "<username>": { "sid": "<sid>", "nb": <epoch> } } }

sids
: a session whose sid is a key here is revoked (sign-out, a revoke from the
  Sessions page). A legacy cookie has no sid, so this cannot reach it.

not_before
: every cookie of that account whose timestamp is **earlier** than the value is
  revoked: "sign out everywhere", legacy cookies included.

kept
: the one exception to `not_before` (SM1040): a credential change signs the
  account's other sessions out and keeps the session that made it. The
  exemption holds only while `nb` equals the account's current `not_before`, so
  a later sign-out-everywhere ends it too.

The file has one writer, `Lazysite::Manager::Sessions` (a sign-out, the
Sessions page, a credential change), which writes it atomically under a lock
and prunes entries older than the session lifetime: they can only match cookies
that have already expired.

# An outside process on the same host

It reads; it never writes. It needs read access to five files in the engine
tree's `auth/` directory - `.secret`, `users`, `groups`, `user-settings.json`,
`revoked.json` - and to `lazysite.conf` for the lifetime; on a packaged install
that means running in the group that owns `auth/`. It needs no lazysite module:
`t/unit/auth/75` verifies with Digest::SHA and file reads alone.

It must not write any of those files, mint cookies, or rotate the key. It must
not take groups from the cookie. It must refuse an `odoo=` session it cannot
check against the registry. Signing in and out stays lazysite's: the outside
process sends a visitor without a valid cookie to the site's `/login`.

# Where it is recorded

The register entries are in `docs/SECURITY.md` (SM1383, confirmed by ruling 146;
SM1390, the three verifier rules above, ruling 147). `t/unit/auth/76` and
`t/integration/361` hold those rules. The live-data pattern that
an outside process sits beside is in the building-sites briefing (`Live data`).
