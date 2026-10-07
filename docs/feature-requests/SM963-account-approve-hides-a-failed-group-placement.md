---
id: SM963
title: "SM963: account-approve hides a failed group placement"
subtitle: "cmd_account_approve wraps the registration-group joins in an eval and skips failures silently, so an account can be created outside the groups it registered for."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: the developer agent, found while building SM858 (approve from a submission)
area: auth
status-note: "Filed 2026-10-07 from the SM858 build (reported, not reproduced here yet). A group join that fails during account-approve is skipped with nothing said, so the approval reads as complete. WORK-PLAN-0153 Q8c."
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
