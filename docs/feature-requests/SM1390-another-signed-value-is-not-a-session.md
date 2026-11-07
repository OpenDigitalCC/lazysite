---
id: SM1390
title: "SM1390: another signed value is not a session, a future timestamp is refused, and the sliding reader is reachable"
subtitle: "Ruling 147: three gaps in the session verifier found at the SM1383 walk, closed as hardening - the preview cookie no longer parses as a session (nor a session as a preview), a timestamp more than 300 s ahead is refused, and the five-field reader runs."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "release manager (ruling 147)"
area: auth
status-note: "SHIPPED (PENDING) on n763, ruling 147: Session.pm refuses a payload beginning v1: and a ts or seen more than 300 s ahead, and splits to five fields so the sliding branch is reachable; gates.pm check_preview requires five fields. t/unit/auth/76 and t/integration/361, each part failing reverted. Hardening; register entry drafted."
---

# What was found

Writing the cookie contract (SM1383) meant checking `verify_session_cookie`
against what it claims, and three things did not hold:

1. The preview cookie (`v1:<exp>:<layout>:<theme>:<user>`, Manager::Preview) is
   signed with the same key as the session cookie, and its value verified as a
   legacy session for an account named `v1`, with that account's groups, with
   the preview's expiry - an hour ahead - as its issue time. The other way
   round, a session for an account named `v1` read as a preview of layout
   `<sid>`, theme `<groups>`, until its issue time passed.
2. The verifier asked only whether a cookie was too old; a timestamp years ahead
   verified for years.
3. The five-field sliding branch (`user:ts:seen:sid:groups`) could never run:
   the payload was split with a limit of four. Such a cookie verified as legacy
   with no sid, and t/unit/auth/16's groundwork assertion read the source, not
   the behaviour.

# What was ruled (147) and built

1. **No purpose prefix in the signed text.** A prefix would change the format
   every cookie in flight carries and every outside reader has just been told;
   the two verifiers can tell the shapes apart as they are. The session verifier
   refuses a payload whose first field is the preview marker (`v1`) before
   reading anything else, as `malformed`; the preview verifier requires exactly
   five fields (a preview is always minted with five, the user possibly empty).
   An account literally named `v1` can therefore no longer hold a session, so
   **no account can be named by the marker**: `lazysite-users.pl add`, `rename`
   and `account-create` (the manager's Users add and an import's approval go
   through add) refuse it with a reason that says why, and an import's
   `stage_accounts` refuses the row; each asks the verifier's own constant
   (`Lazysite::Auth::Session::PREVIEW_MARKER`), never a literal. An account
   that already carried the name is named by `lazysite check`, with the rename
   as the remedy.
2. **A timestamp more than 300 seconds ahead is refused** (`CLOCK_SKEW`), on
   `ts` and on `seen`; the contract document states the allowance.
3. **The five-field branch is reachable on purpose**: split limit 5. Groups never
   contain colons, so the four- and three-field cookies parse as before. Nothing
   issues five fields yet; the contract document describes the shape as read,
   not issued.

Tests: `t/unit/auth/76` (a preview value as a session, fresh and expired; a
future `ts` and `seen`, inside and outside the skew; the five-field cookie with
its sid and its age from `seen`; the two issued shapes still verifying),
`t/integration/361` (a session-shaped value as a preview, four and three
fields; a five-field preview with an empty user still previewing),
`t/unit/users/71` (add, rename, account-create and the import's stage refuse the
name, naming the marker and why) and `t/tools/333` (the check names an
existing account so named, OK otherwise). Each part reverted fails its test
(`tmp/n763-sabotage-2.sh`, `tmp/n763-sabotage-3.sh`).

# Left open

- Sliding expiry still has no writer (SM297's subject).
