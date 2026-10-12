---
id: SM1043
title: "SM1043: a member changes their own password and ends their own sessions, on /account"
subtitle: "SM1034 phase 1a, ruled \"Accept, build phase 1\" 2026-10-12. The /account system page in the site theme, its built-in components, and the closed me-* action family whose subject is always the caller."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1034 phase 1a, ruled by the release manager 2026-10-12
area: accounts
status-note: "SHIPPED (PENDING): /account joins the SM201 system pages (site layout, self-healing, account_page switch); ::: account-summary/-password/-sessions with /assets/lazysite-account.js; me, me-password, me-sessions, me-session-revoke, me-sign-out-everywhere - declared self, cookie-only, CSRF-gated, audited; password checks count against the sign-in rate limiter. t/unit/account/01-02, 05, lint 246."
---

# The ruling

SM1034, ruled 2026-10-12: "Accept, build phase 1", with Q1 (`me-*` actions on
the control API), Q2 (on by default, `account_page` to turn it off), Q3
(re-authenticate per sensitive request with the current password) and Q8 (land
at `/` with a link to `/account`) as recommended.

# What was built

- **`/account` is a system page.** `account` joins `%SYSTEM_PAGES`
  (lazysite-processor.pl), with an engine default at
  `lazysite/templates/system/account.md` (`auth: required`). It renders in the
  domain's own layout and theme, a site's own `account.md` wins, and a deleted
  copy falls back to the default. `account_page: disabled` withdraws the
  default (404) and turns the actions off; the processor's copy of the switch
  (ADR 0001) and `Lazysite::Util::account_page_enabled` are held to one answer
  by `t/unit/account/01`.
- **Built-in components**: `::: account-summary`, `::: account-password`,
  `::: account-sessions` under `lazysite/templates/components/`; a layout's
  component of the same name wins. The processor adds
  `/assets/lazysite-account.js` to a page carrying a `data-ls-account` region
  (as it does the data helper), and serves it as an engine asset on every
  domain. The script inserts values as text only.
- **The `me-*` family** (`Lazysite::Manager::Account`): `me`, `me-password`,
  `me-sessions`, `me-session-revoke`, `me-sign-out-everywhere`. Each is declared
  `self => 1` in `Lazysite::ControlApi::Actions`, which refuses at load a self
  action in the token gate, with a capability, an MCP twin, or a parameter that
  names an account. `t/lint/246` holds the same and more: every `me`/`me-*` is
  self, its dispatch branch passes no argument, and the module reads no query
  parameter and no account-naming key of the body.
- **Re-authentication and rate limiting.** `me-password` carries the current
  password; every check counts against the sign-in rate limiter by the
  caller's address and by the account (`account=<login>`), five per five
  minutes, so a stolen session is not an unthrottled password oracle. The
  limiter moved, unchanged, from lazysite-auth.pl to `Lazysite::Auth::LoginRate`
  so both doors count against one counter (`t/unit/auth/24` reads it there).
- **The new password** meets SM1041's policy, and the change goes through the
  users tool's `passwd` with the session's verified id, so SM1040 signs the
  account's other sessions out and keeps this one.
- **Sessions**: `me-sessions` lists the caller's own live sessions;
  `me-session-revoke` ends one of them - an id that is not the caller's answers
  exactly as an id that does not exist (not-found, never forbidden), so ids
  cannot be probed; `me-sign-out-everywhere` ends all of them, this one too.
- **Audit**: the generic block records each write against the account; the
  body is never recorded. A wrong current password is a `fail` row.
- The login page's "already signed in" panel links to `/account`.

# Security, tested

`t/unit/account/02` through the real manager API and the real auth wrapper:
a member with no capability reads and changes only their own account; a body
naming another account changes nothing of theirs; another account's session id
is indistinguishable from a made-up one and that session stays signed in; a
POST without the CSRF token, a GET, an unauthenticated caller and an access key
are refused; a wrong current password changes nothing, signs nobody out and is
audited; six guesses from six addresses close the account's bucket; the audit
trail carries no password; `account_page: disabled` turns each action off,
naming the setting. Sabotaged one at a time (no re-authentication, no rate
limit, any session revocable, a token reaching the module, the switch ignored
by actions or page, not a system page, the helper not injected, a self action
taking `username`, the handler reading an account) - each fails a test.

# Design choices, confirmed

Raised as choices the rulings did not settle; the release manager confirmed
each as built, 2026-10-12, in these words:

- `me-sign-out-everywhere` ends the current session too: **"Yes, including this
  one"**. A member who wants to stay signed in ends sessions one by one, or
  changes the password, which keeps the current session.
- `account_page` is instance-wide (one account store serves every domain), and
  a site that writes its own `account.md` keeps it when the switch is off:
  **"Instance-wide"**.
- Re-authentication on `/account` counts against the sign-in rate limiter, by
  address and by account, five checks in five minutes: **"Share the sign-in
  limit"**.

# The manager door (SM1057)

SM1057 made the manager API's cookie door require `ui`. A member - who
`/account` is for - holds none, so the door lets an action declared `self` past
that gate, and nothing else: the set is `Actions::self_actions()`, whose
load-time checks refuse a self action in the token gate, with a capability, an
MCP twin, a path scope, a content write, a file surface, an instance-wide
effect or an account-naming parameter; lint 246 holds the gate to that
declaration. `csrf-token` is answered before the gate. SM1057's content-write
gate catches no `me-*` action: none is a content write, and the declaration
refuses one that says it is. `t/unit/account/05`: a member without `ui` uses
every self action and `/account`, and is refused 403 at the door on every other
cookie action, `save` included; dropping the exemption, or widening it to every
action, fails it.
