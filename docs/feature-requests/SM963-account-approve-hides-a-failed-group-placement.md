---
id: SM963
title: "SM963: account-approve hides a failed group placement"
subtitle: "cmd_account_approve wraps the registration-group joins in an eval and skips failures silently, so an account can be created outside the groups it registered for."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the developer agent, found while building SM858 (approve from a submission)
area: auth
status-note: "SHIPPED (PENDING) (n264). Reproduced with a flagged backend group: approve answered ok, group [learners], the other dropped unsaid. Each failed placement now comes back in `unplaced` with its reason - CLI lines, Users API result, both audit trails, SM858's result and its dialog. The account is still made. t/unit/users/49, ten sabotages."
---

# Reported

`cmd_account_approve` places the new account in the groups its registration
flagged, inside an `eval` whose failure is skipped. The approval then reports
success for an account that is missing a group it was meant to have - an
absence reported as a success.

# Proposal

Collect each failed placement and report it in the result (the account is still
created; the operator is told which groups did not take). Reproduce first.

# Done when

A failed placement appears in the approve result and the audit detail; a test
with a group that cannot be joined asserts it.

# Reproduced (n264)

Through the real tool on a fresh site, before any change: `learners` and
`vault` both flagged to take registrations, `vault` a backend group (assignable
off - `group-add` refuses to give one to a person). `account-approve alice`
printed "Approved 'alice' into learners." and the Users API answered
`{"ok":1,"group":["learners"],...}` - `vault` was dropped with nothing said,
and the CLI trail read "registration approved; placed in learners". SM858's
approve button answered the same, and its trail recorded only
`id=... account=fay`.

# The fix

The join loop collects each failure as `{group, error}` - `cmd_group_add`'s own
reason - into `unplaced`, which every result made after the account exists now
carries (present and empty when everything took). The account and its link are
still made; nothing is rolled back.

- CLI: a `NOT placed in '<group>': <reason>` line each, then how to place it.
- CLI trail: `...; placed in learners; NOT placed in vault`.
- Users API: `unplaced` in the result; the manager's trail adds
  `not-placed=vault` (the tool audits only on the CLI, so the manager says it).
- SM858: `action_form_submission_approve` passes `unplaced` through, its trail
  reads `id=... account=fay not-placed=vault`, and the viewer's success dialog
  names each group and why.

# Evidence

t/unit/users/49: Users API result, CLI output and trail, manager Users API
result and trail, an explicit `--group` that cannot take, an all-placed approval
(`unplaced` empty, no CLI line), and SM858 end to end through the real form
handler and the manager API. Before the fix 11 of its assertions failed.
Ten sabotages, each restored and checked with cmp: the ok result without
`unplaced`; the CLI trail without it; SM858 dropping it; each manager trail line
removed; every group reported unplaced; a generic reason; the old silent skip;
a failed placement aborting the approval; a joined group not recorded.
