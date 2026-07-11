---
title: "SM141 - Session registry: list + control active sessions"
brand: plain
status: shipped
status-note: "landed across 2 release(s), 0.6.10 .. 0.7.3"
---

# SM141 - Session registry: list + control active sessions

Status: BUILT (option B, phase 1 - no last-seen) 2026-07-10; scoped earlier
the same day. See "What shipped" at the end.
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

## What shipped (phase 1, 2026-07-10)

Cookie format
: `lazysite_auth` payload is now `user:ts:sid:groups` (sid = 16 random hex
  chars). Verification accepts BOTH shapes: the legacy 3-field
  `user:ts:groups` stays valid until natural expiry (groups can contain
  commas but never colons, so a limit-4 split + the 16-hex sid shape check
  disambiguates). Legacy cookies carry no sid but are killable per-user via
  `not_before` (they carry `ts`).

Registry
: `lazysite/auth/sessions.jsonl` - one `{sid, user, t, ip, ua}` line per
  login (ua control-stripped + truncated to 120, the SM140 recorder's
  sanitisation pattern; the wrapper keeps its own small copy,
  `_session_field`). Self-prunes lines older than COOKIE_MAX on write
  (atomic temp+rename, 0660). Registry failure never blocks login
  (eval-guard + WARN).

Revocation
: `lazysite/auth/revoked.json` - `{ sids => {sid: revoked_at},
  not_before => {user: epoch} }`, checked in the auth wrapper's
  cookie-verify path after signature+expiry: reject a revoked sid, or a
  cookie issued before the user's `not_before`. Fast path is a single `-f`
  stat (absent file = nothing revoked); an unreadable/corrupt file is
  treated as empty with a loud WARN (fail-open-with-alarm - a corrupt file
  must not lock everyone out; lazysite-check probes both files). Writers
  prune entries older than COOKIE_MAX.

Manager surface
: manager-api actions `sessions-list` (live sessions only: fresh, not
  revoked, at/after `not_before`; `current` marked via the
  `LAZYSITE_AUTH_SID` env the wrapper passes to its children),
  `session-revoke {sid}` and `user-revoke {username}` - all gated on
  `manage_users` (cookie side; token clients cannot reach them), the two
  revokes audited (target = sid prefix / username). The Sessions page shows
  the live table (user / signed in / IP / device / "this session") with
  per-session Sign out and per-user Sign out everywhere; secret rotation
  stays as the nuclear option.

Deviation from the scoping text
: the revocation check lives ONLY in the auth wrapper. The scoping assumed
  a second local copy in the processor's check_auth, but the processor never
  validates the auth cookie - it trusts the `X-Remote-*` headers the wrapper
  sets when it execs the processor / manager-api - so there is exactly one
  enforcement point and no copy to keep in sync.

Tests
: `t/unit/auth/12-session-registry.t` (mint shape, registry sanitisation,
  legacy acceptance, sid + not_before revocation incl. a legacy-shape
  cookie, corrupt-file fail-open WARN, registry prune) and
  `t/unit/manager/24-sessions.t` (list shape + current marking, gating,
  audit targets, writer prune).

Phase 2 (not built)
: last-seen (bounded touch or derived from the SM140 first-party log).
