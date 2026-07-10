# SM141 - Session registry: list + control active sessions

Status: scoped 2026-07-10 (exploration; not yet committed to build)
Driver: the Sessions page currently exposes only "log out everyone" (rotate
the auth secret) because sessions are signed cookies with no server-side
record. Operators want to see who is signed in (who / when / where /
last-seen) and to end an individual session.

## The constraint

Sessions are STATELESS by design: `lazysite_auth = user:issued-at:groups:hmac`,
verified per request against the site secret, valid for 24h (COOKIE_MAX).
There is nothing to list and nothing to revoke short of rotating the secret
(everyone) or disabling the account (per user, checked per request already).
Any per-session control necessarily adds server-side state; the design
question is HOW MUCH state and WHERE it sits on the hot path.

## Options

### A. Full server-side sessions (rejected)

The cookie becomes an opaque session ID; user/groups/expiry live in a store
read on EVERY request, with last-seen written per request. This is the
conventional model and the wrong one here: it inverts the stateless design,
puts a read+write on the hottest path, makes the store a single point of
failure (store gone = everyone logged out), and reverses a deliberate
architecture decision for a feature that is occasionally used.

### B. Signed cookies + registry + revocation list (RECOMMENDED)

Keep the cookie exactly as the source of truth; add two SMALL, loss-tolerant
side structures:

Session registry (for LISTING - advisory metadata)
: at login, mint a short random session id (sid), embed it in the cookie
  payload (`user:ts:sid:groups` + hmac), and append one line to
  `lazysite/auth/sessions.jsonl`: sid, user, issued-at, IP, truncated UA.
  Losing this file logs nobody out - it only degrades the listing. Pruned on
  write: entries older than COOKIE_MAX are dead by definition (24h bound), so
  the file stays tiny (= logins per day).

Revocation list (for CONTROL - fail-closed, hot-path-cheap)
: `lazysite/auth/revoked.json`: a set of revoked sids + an optional per-user
  `not_before` timestamp. Cookie verification (auth wrapper AND the
  processor's check_auth; local copy per ADR 0001) adds: reject if sid is
  revoked, or if issued-at < not_before{user}. Hot-path cost when nothing is
  revoked: one `-f` stat (the bad-url-blocker precedent); when present: one
  tiny JSON read. Entries self-expire: anything older than COOKIE_MAX can be
  dropped, so the list never grows.

What this buys
: - Sessions page lists live sessions (issued within 24h, not revoked):
    who / when / IP / device, with "this session" marked.
  - Per-session "Sign out" (revoke sid).
  - Per-user "Sign out everywhere" (`not_before{user} = now`) - kills all of a
    user's cookies WITHOUT the global secret rotation, including legacy
    cookies minted before this feature (they carry issued-at).
  - "Log out everyone" (secret rotation) remains for the nuclear case.

Last-seen (optional, phase 2)
: a per-request last-seen write is exactly the hot-path cost option A was
  rejected for. If wanted: a bounded touch (at most once per N minutes per
  sid, mtime-gated marker) or derive activity coarsely from the SM140
  first-party log. Phase 1 ships issued-at only, which is honest and cheap.

### C. Status quo + levers (insufficient)

Document COOKIE_MAX, point at disable-account and Reset credential. Does not
meet the ask; listed for completeness.

## Privacy and compatibility notes

- Storing IP + UA in the registry matches the audit trail's existing
  precedent (it already records operator IPs); 24h retention by construction.
  The registry lives in `lazysite/auth/` (0770, never web-served).
- Cookie format gains a field (sid). Old cookies remain valid until expiry
  (verification accepts both shapes for one COOKIE_MAX window); they list as
  "legacy session" and are still killable via per-user not_before. Additive,
  not breaking - no migration needed, safe relative to the 1.0 compat freeze.
- The revocation check is fail-closed on parse errors (unreadable list =
  treat as empty but WARN loudly, since silently failing closed would log
  everyone out on a corrupt file; lazysite-check gains a probe).

## Sizing (option B, phase 1)

Auth wrapper: mint sid + registry append + revocation check (~80 lines).
Processor check_auth: revocation check local copy (~30 lines). Manager API:
`sessions-list` / `session-revoke` / `user-revoke` actions gated on
`manage_users` (~80 lines). Sessions page UI rework (~100 lines). Tests:
integration (login -> list -> revoke -> cookie rejected; legacy-cookie
not_before; prune) + unit. Roughly an SM113-sized build.

## Recommendation and sequencing

Build option B, phase 1 (no last-seen) - but AFTER the eight-dimension
review and the 0.7.0 stable cut: it touches the auth hot path, which is
exactly what should not churn while a review is in flight. It is additive
(no on-disk breaking change), so it does not need to beat the compat freeze.
