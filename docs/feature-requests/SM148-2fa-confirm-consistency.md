---
title: "SM148 - 2FA confirm step + manager UI consistency"
subtitle: "No accidental 2FA lockout; one button/style vocabulary"
brand: plain
status: shipped
status-note: "delivered 2026-07-12; two-step 2FA (pending until a code confirms; sign-out-now on your own account), global button style, hierarchy accent bar, add-user/add-group own cards, Sessions & keys nav, username links, Groups restyled to match"
---

# SM148 - 2FA confirm step + manager UI consistency

## 2FA cannot lock you out by accident

Clicking "Enable 2FA" enrolled immediately, so exploring the control could turn
on 2FA and lock the user out at the next login. Now enrolment is **two-step**:

- Enrol is **pending** - a secret + recovery codes are generated but 2FA is
  **not enforced at login** (`mfa_pending`); `mfa_enrolled` (the enforced state)
  stays false. The control shows *Set up 2FA* / *setup not confirmed* / *enabled*
  accordingly.
- Setting up shows the QR, the copyable secret, and a **Confirm & enable** field:
  only a valid code from the app clears `mfa_pending` and turns 2FA on. A wrong
  or absent code leaves it off; **Cancel setup** / **Restart setup** drop or
  redo a pending enrolment.
- On confirming your **own** account, you are signed straight out to sign back
  in with 2FA - so you prove it works now rather than discover a lockout later.

Backend: `mfa-enroll` sets `mfa_pending`; new `mfa-confirm` verifies a code and
clears it; `lazysite-auth.pl` `mfa_enrolled()` and `effective_settings` treat a
pending secret as not-enrolled. Tests updated (`07-mfa-login`, `14-totp`).

## Manager UI consistency

From the same review:

- **Buttons** everywhere now carry a low background at rest that lifts on hover,
  so every action reads as a button (was transparent-until-hover, i.e. looked
  like text).
- The account **hierarchy** bar is the accent colour (was a grey line).
- **Add user** and **Add group** are their own cards, outside the list card.
- Nav item is **Sessions & keys**; usernames on the Sessions/keys tables and
  group member chips link to that account's Users-page row.
- The **Groups** page (which shared the old accordion styling the Users refactor
  changed) is restyled to the same one-line summary + accent conventions.

## Open

- A broader pass for any remaining one-off styles across manager pages
  (files/backups/config) so there is a single visual vocabulary throughout.
