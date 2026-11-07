---
id: SM1383
title: "SM1383: the session cookie is an external contract"
subtitle: "Ruling 132, E: an outside process on the same host may share a lazysite sign-in by verifying lazysite_auth read-only, so the cookie's format is written down, verified against the code, and pinned by a test."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager (ruling 132)"
area: auth
status-note: "SHIPPED (PENDING) on n763, ruling 132 E: docs/architecture/session-cookie-contract.md states the format, key, expiry and revocation; t/unit/auth/75 mints through the real sign-in and verifies as an outside process would, agreeing with the engine. SECURITY.md entry drafted. Found: the preview cookie verifies as a session for an account named v1."
---

# What was asked

Ruling 132, E: document the auth cookie as an external contract, so that an
outside process on the same host can verify a lazysite sign-in read-only, and
pin the format so a silent change fails the suite. Identity in-process (C,
SM297) waits for X4.

# What shipped

- `docs/architecture/session-cookie-contract.md`: the cookie and its attributes;
  the `username:timestamp:sid:groups` payload and the legacy
  `username:timestamp:groups` variant, valid until natural expiry; the key
  (`auth/.secret` in the engine tree, used as its hex text, never its value);
  constant-time comparison; expiry against `session_lifetime`; `revoked.json`
  (revoked sids, per-user `not_before`, the SM1040 `kept` exception); fresh
  groups; and what an outside process reads, and must not do. The format will
  not change silently, and is versioned if it must.
- `t/unit/auth/75`: a cookie minted by the real sign-in, verified with
  Digest::SHA and file reads alone, agreeing with `verify_session_cookie` on
  every case the document names. It fails when `_mint_session`'s sid length or
  separator changes, and when the legacy shape stops verifying.
- A `docs/SECURITY.md` entry: new-external-interface fires in a narrow form.

# Found while verifying

These are recorded for the release manager; none is changed here.

1. **The key is symmetric.** A process that can verify can mint a cookie for any
   account. The document says so; "read-only" is a promise, not a limit.
2. **No domain separation.** The same key signs the preview cookie
   (`v1:<exp>:<layout>:<theme>:<user>`) and the CSRF tokens. A preview value
   verifies as a legacy session for an account named `v1`, with its groups, when
   that account exists (`tmp/n763-preview-as-session.pl`). The verifier also
   accepts a future timestamp, which the preview's expiry supplies.
3. **The five-field reader is unreachable.** `verify_session_cookie` splits on
   `:` with a limit of four, so its `@f == 5` branch never runs; a sliding-expiry
   cookie written as its comments describe would verify today as legacy, with no
   sid. The "readers before writers" groundwork does not hold.

# Questions for ruling

1. Should the session payload gain a domain prefix (versioned, reader first), or
   should the preview and CSRF payloads, so no other signed value can parse as a
   session?
2. Should the verifier refuse a timestamp in the future?
3. Should the five-field branch be fixed (limit 5) before any writer issues it,
   or removed until sliding expiry is built?
