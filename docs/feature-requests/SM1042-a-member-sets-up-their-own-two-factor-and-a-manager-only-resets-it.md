---
id: SM1042
title: "SM1042: a member sets up their own two-factor, and a manager only resets it"
subtitle: "SM1034 phase 1c, ruled 2FA \"Self-enrol only\" 2026-10-12. Only a user manager could enrol 2FA, for someone else, and saw that person's secret and recovery codes in doing so."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1034 phase 1c and Q6, ruled 2FA "Self-enrol only" by the release manager 2026-10-12
area: accounts
status-note: "SHIPPED (0.15.5): me-2fa-enrol (password), me-2fa-confirm (code), me-2fa-disable and me-recovery-codes (password + code; disable ends other sessions) with ::: account-2fa; the manager API refuses mfa-enroll/-confirm/-recovery-regenerate/-verify/totp-code, the users tool refuses them for another actor, and the Users page offers reset only. t/unit/account/04."
---

# The ruling

The release manager, 2026-10-12, on SM1034:

> 2FA - "Self-enrol only": members enrol their own 2FA (phase 1c); managers can
> only reset or disable someone's 2FA and never see a secret or recovery codes;
> until 1c lands manager enrolment stays so nobody is locked out - so remove
> manager enrolment in the SAME branch as 1c, not before.

# What was built

- **The member's own two-factor** (`Lazysite::Manager::Account`), four `self`
  actions: `me-2fa-enrol` (the current password; refused while 2FA is on, so a
  stolen session that has the password cannot swap the authenticator),
  `me-2fa-confirm` (a code from the app turns it on), `me-2fa-disable` (the
  password and a current code or one recovery code; a set-up never confirmed is
  cancelled with the password alone; SM1040 signs the other sessions out) and
  `me-recovery-codes` (the password and a current code; eight new codes replace
  every old one - a new users-tool verb, `mfa-recovery-regenerate`, as there
  was none short of disable-and-enrol). Every check counts against the sign-in
  rate limiter. The secret and codes are returned to the account and nowhere
  else.
- **`::: account-2fa`** on `/account`: the QR drawn from the bundled library as
  integers, the key as text, the recovery codes once.
- **Manager enrolment removed, in this branch** as ruled: the manager API's
  `users` action refuses `mfa-enroll`, `mfa-confirm`, `mfa-recovery-regenerate`,
  `mfa-verify` and `totp-code` (a manager verifying a member's code would spend
  their recovery codes); the users tool refuses the three enrolment verbs to any
  actor that is not the account; the Users page offers **Reset 2FA** (and
  Cancel setup for a pending one) and points an account with none at
  `/account`. A manager's reset still signs that account out everywhere.

# Tests and sabotage

`t/unit/account/04`: a user manager is refused each verb and gets no secret,
for another account and its own; the users tool refuses another actor; the
member enrols, confirms, cannot re-enrol while on, makes new recovery codes
(old ones then fail), cannot disable with the password alone, disables with a
code (this session stays, the other ends); a manager can still reset; the Users
page carries no enrolment and no secret. Sabotaged (the manager refusal, the
tool's actor check, enrol-while-on, disable without a code, old codes kept) -
each fails.

# Design choices, confirmed

Raised as choices the ruling did not settle; the release manager confirmed
them as built, 2026-10-12, in these words:

- The sysadmin at the shell keeps `lazysite-users.pl mfa-enroll USER`: **"Keep
  for the shell"**. It is the host, not a manager, and the tool's actor check
  exempts no-actor calls as it does for every verb - the recovery path for a
  site whose only sysop has lost their authenticator and their codes.
- Re-authentication counts against the sign-in rate limiter: **"Share the
  sign-in limit"** (recorded in SM1043). Five checks per five minutes can stop
  a member who changes a password, sets up 2FA and mistypes a code in one
  sitting; they wait five minutes.
- The brief's `account_2fa` switch stays unbuilt, because it was not ruled; 2FA
  follows `account_page`.
