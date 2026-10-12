---
id: SM1041
title: "SM1041: a password has a minimum length, and the operator sets it"
subtitle: "SM1034's password-policy item, ruled \"Min 12, configurable\" 2026-10-12. The only refusal was an empty password."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1034 (no password policy beyond non-empty), ruled "Min 12, configurable" by the release manager 2026-10-12
area: accounts
status-note: "SHIPPED (PENDING): password_min_length in lazysite.conf, default 12 (8-128, else the default), asked by one reader in Lazysite::Auth::Credential and applied to add, passwd, account-create, setup-sysop and claim/reset redemption; existing passwords keep working. A too-short claim leaves the link unused. t/unit/auth/41."
---

# The ruling

The release manager, 2026-10-12, on SM1034:

> "Min 12, configurable": `password_min_length` in lazysite.conf, default 12,
> applied to EVERY way a password is set (users tool add/passwd, claim/reset
> redemption, setup-sysop, me-password); existing passwords keep working until
> changed. Its own SM, its own branch.

# What was wrong

SM1034 read it (A): `claim-redeem` refused only an empty password, and `add`
and `passwd` refused nothing - `add alice pw` succeeded.

# The fix

- **One reader.** `Lazysite::Auth::Credential::password_min_length` reads
  `password_min_length` from lazysite.conf; `password_policy_refusal` answers
  with one sentence naming the length and nothing about any account. A value
  outside 8-128 is a typo, not a policy, and the default stands (8 is the NIST
  SP 800-63B floor for a chosen password). Characters are counted, not bytes.
- **Every door.** The users tool asks it in `cmd_add` and `cmd_account_create`
  (a non-empty password; empty is still a token-only account), `cmd_passwd`
  (every door: CLI, manager, `setup-sysop` on an existing account) and
  `cmd_claim_redeem`. The member's own change on `/account` (SM1043) goes
  through `passwd`. The check runs before anything is written - before SM1040's
  revocation too, so a refused password signs nobody out.
- **A link is not spent on a short password.** The claim is checked first, then
  the policy; a refusal returns `invalid` on field `password` and leaves the
  claim valid. The auth CGI sends the person back to `/claim` with
  `error=short&min=N`, and the page says how long a password must be.
- **Existing passwords keep working.** Nothing asks the policy when a password
  is checked; a two-character password set before this still signs in.
- `setup-sysop --link`'s placeholder is 128 hex characters and its generated
  password grows with the policy, so neither can be refused.

# The suite

Every password the suite SETS had to be 12 characters or more: 146 test files
failed only on the policy (measured by re-running them with the default set
to 1). Each short literal a file sets was lengthened where that file sets and
uses it (`tmp/pw-rewrite.pl`, then by hand), and the files that passed with a
short password - because the account they meant to create was refused and
nothing noticed - were lengthened too, so a refusal they assert is refused for
their reason and not the policy's.

# Tests and sabotage

`t/unit/auth/41`. Sabotaged one at a time (backups under
`tmp/sab-bak/sm1034/`, restored and compared): passwd skipping the policy,
claim redemption skipping it, the reader ignoring lazysite.conf, counting
bytes, and the auth CGI sending a short password to the spent-link page - each
fails the test.
