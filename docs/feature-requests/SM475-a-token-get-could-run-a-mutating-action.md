---
title: "SM475: a token client could run a state-changing action with GET"
subtitle: "The POST requirement lived inside the cookie branch, so it never applied to a token client. An authenticated GET of data-migrate returned 200 and ran."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED 2026-08-22 from edge: an authenticated GET of ?action=data-migrate returned 200 and RAN - a no-op only because the schema happened to be current - and an authenticated GET of data-row-save reached its body check. CAUSE: the %MUTATING method check sat inside `if ( !$token_auth )`, the block whose comment explains it in CSRF terms. CSRF is the cookie path's reason and is not the only one: a state-changing action reachable by GET is prefetchable, is retried by any intermediary that believes GET is safe, and lands in logs and browser history as a URL somebody can paste. FIXED by hoisting the check above the channel split, so it applies to both. t/lint/14 now asserts the check appears BEFORE the split, which is the property rather than its current position. WHY THE TESTS MISSED IT: t/integration/53 drove the cookie path only - it asserted the refusal on the channel that already had it."
---

# Where the rule lived

The block's own comment reads *"a state-changing action must be POST (a GET
would bypass the CSRF gate above)"*. That is true, and it is a reason
particular to browsers. Sitting inside the cookie branch made the rule
particular to browsers too.

A token client has no ambient credentials and no CSRF exposure. It still
should not change state on a GET, for the ordinary reasons: prefetch, retry,
and the fact that a URL travels.
