---
id: SM1040
title: "SM1040: a changed credential signs the account's other sessions out"
subtitle: "SM1034's security item, ruled \"Fix now\" 2026-10-12. A password change or a 2FA disable wrote the new credential and nothing else, so a stolen session outlived the change it prompted."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1034 (Changing one's password today), ruled "Fix now" by the release manager 2026-10-12
area: accounts
status-note: "SHIPPED (0.15.5): passwd (own or an operator's, every door), a redeemed setup or reset link and a 2FA disable end every other session of the account, legacy cookies included; the session making the change stays, named beside its not_before and taken only from the verified cookie. revoked.json writes are locked. t/unit/auth/40."
---

# The ruling

The release manager, 2026-10-12, on SM1034, "Fix now":

> any password change (own, an operator's passwd, a redeemed reset/claim link)
> and any 2FA disable revokes that account's OTHER sessions; the current
> session stays. Its own SM, its own branch first, test + sabotage.

# What was wrong

SM1034 read it (A): `not_before`, the "signed out everywhere" marker, appeared
nowhere in `tools/lazysite-users.pl`. `passwd`, `claim-redeem` and
`mfa-disable` wrote the new credential and returned. A session taken before the
change - the reason a person changes a password - stayed signed in for the rest
of its lifetime.

`t/unit/auth/40` reproduced it before the fix: after `passwd`, a session minted
a minute earlier still signed in through the auth wrapper.

# The fix

- **One mechanism.** `Lazysite::Manager::Sessions::revoke_account_sessions`
  sets the account's `not_before` to now - the same marker "Sign out
  everywhere" writes, which also ends legacy cookies that carry no session id.
- **Every door.** The users tool calls it from `cmd_passwd` (the CLI, the
  manager's Users page, `setup-sysop` on an existing account), from
  `cmd_claim_redeem` (both purposes) and from `cmd_mfa_disable` when something
  was enrolled. It runs FIRST: a revocation that cannot be written dies with
  "nothing was changed" and the old credential stands.
- **The session making the change stays.** It is named in `kept`, beside the
  `not_before` it is exempt from. The verifier (`Auth::Session::session_revoked`)
  and the Sessions listing admit it only while that `not_before` stands, so the
  next sign-out-everywhere ends it too; `user-revoke` also drops the entry.
- **Who may name it.** Only engine code, from the verified cookie: the manager
  API's `users` action deletes any `keep_sid` a request body carries and sets
  it from `LAZYSITE_AUTH_SID` only for `passwd` or `mfa-disable` on the
  caller's own account. An operator resetting someone else keeps none of that
  person's sessions. A redeemed link authenticates by its claim, not a session,
  so it keeps none.
- **Serialised writes.** Every write of `revoked.json` (a logout, a session
  revoke, sign-out-everywhere, this) holds `revoked.json.lock`, so two at once
  cannot drop each other's entry.

# Tests and sabotage

`t/unit/auth/40` changes a credential through each door and asks the auth
wrapper which cookies still sign in. Sabotaged one at a time (backups under
`tmp/sab-bak/sm1034/`, restored and compared): passwd revoking nothing, a
redeemed claim revoking nothing, the verifier ignoring the kept session, the
listing ignoring it, a body `keep_sid` honoured, and 2FA disable revoking
nothing - each fails the test.
