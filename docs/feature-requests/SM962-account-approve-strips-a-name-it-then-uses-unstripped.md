---
id: SM962
title: "SM962: account-approve creates a stripped username, then uses the unstripped one"
subtitle: "cmd_add silently strips invalid characters (jo+hn becomes john) while cmd_account_approve goes on with the original name for groups and the claim."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: the developer agent, found while building SM858 (approve from a submission)
area: auth
status-note: "Filed 2026-10-07 from the SM858 build (reported, not reproduced here yet). Through the CLI or Users API, account-approve with an invalid name may create a stripped account the rest of the step never reaches. SM858's button validates first, so it is unaffected. WORK-PLAN-0153 Q8b."
---

# Reported

The users tool's `cmd_add` strips characters a username cannot hold
(`jo+hn` -> `john`), and `cmd_account_approve` then calls `cmd_group_add` and
`cmd_claim_create` with the UNstripped name. Through the CLI or the Users API an
approval with such a name may create `john` and then fail - or act on nothing -
for the group placement and the claim.

# Proposal

Refuse an invalid name by name before anything is created (as SM858's button
does), rather than stripping it in `cmd_add`. Reproduce first.

# Done when

account-approve with an invalid name creates nothing and says why; a test
asserts it.
