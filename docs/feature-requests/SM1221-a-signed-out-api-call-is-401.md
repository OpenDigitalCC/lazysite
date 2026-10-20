---
id: SM1221
title: "SM1221: a signed-out manager-API call is 401"
subtitle: "A request with no sign-in answered 400, the status for a malformed request. It answers 401 with the body it had; a site with no manager account answers 503."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the 0.15.12 walk, Y4 (inbox/archive/2026-10-20-test-plan-01512-results.md)"
area: manager
status-note: "SHIPPED (PENDING) on n708: kind unauthenticated -> 401 (cookie session, so no WWW-Authenticate); no manager account -> 503 not-set-up. t/unit/manager/390, 391; t/integration/243 now expects 401."
---

# What happened

`lazysite-manager-api.pl` ended an unauthenticated request through `_bail`, whose
body had no `kind`, and `respond` gives a refusal with no kind `400 Bad Request`.
A client keying on the status read a well-formed request that only lacked a
sign-in as its own mistake.

# Ruling

2026-10-20 (Manager API): "401 for signed-out".

# What shipped

- The refusal carries kind `unauthenticated`, which `%REFUSAL_STATUS` maps to 401.
  The error wording is unchanged.
- No `WWW-Authenticate` header. The header names an HTTP authentication scheme; the
  session here is a cookie. Basic would make a browser raise its own password prompt
  over the manager, and an invented scheme names nothing a client knows.
- A site with no manager account yet (not secured) keeps its wording and answers 503,
  kind `not-set-up`. 401 invites a sign-in, and there is no account to sign in with
  until the operator runs `setup-sysop`; 503 says the service is not yet available.
- Clients: the manager pages' shared fetch wrapper already reads 401 as a lapsed
  sign-in (SM445) and shows "sign in again" once; no page keyed on 400 for this. MCP
  has its own authentication and does not use this path. The only tests that asserted
  400 for it were t/integration/243, now 401.
- Not changed, and open: "Invalid credentials" and "Do not combine cookie and token
  auth" are still 400 (a bad token is arguably 401 too).
