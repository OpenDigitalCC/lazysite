---
title: "SM549: actor local is one actor in the users tool"
subtitle: "account-disable, account-enable and account-reassign refuse actor local while passwd, rename, claim and account-create exempt it, so the same caller gets two answers from one tool."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): _authorise_manage now treats actor local as the operator sentinel it is (SM268 C1), so account-disable, account-enable and account-reassign give the same verdict with actor local as with no actor; proving test t/unit/users/32-local-is-one-actor.t drives every actor-taking verb both ways and failed on the three before the fix. FOUND 2026-08-25 by the tools structural review, PROVEN by probe tmp/probe-users-local-actor/result.txt; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. tools/lazysite-users.pl treats actor local two ways: five inline actor-confinement blocks (passwd, rename, claim, account-create) exempt it, while _authorise_manage at 1538 does not, so account-disable, account-enable and account-reassign with actor local are refused with 'Not authorised to manage' and the identical call with no actor succeeds. Whether local should be honoured at all is SM268 C1's decision; the cleanup TO-9 that would unify the six blocks waits on that answer."
---

# The finding

`tools/lazysite-users.pl` gives `actor: local` two answers. Five inline
confinement blocks (`lazysite-users.pl 742-745, 785-789, 1455-1458,
1877-1879, 1930-1932`) exempt it for passwd, rename, claim and
account-create; `_authorise_manage` (`lazysite-users.pl 1538-1543`)
encodes a different rule and refuses it for account-disable,
account-enable and account-reassign. The probe shows passwd and rename
with actor local returning ok, account-disable and account-reassign
returning `Not authorised to manage 'bobby'`, and the same calls with no
actor succeeding.

# Why it matters

Correctness: one caller identity produces opposite verdicts from verbs
of the same tool, so an automation that passes `actor: local` works for
some account operations and is refused for others with no rule that
explains the split.

# The proving test

NEW `t/unit/users/32-local-is-one-actor.t`: for every actor-taking verb,
`actor => 'local'` and no actor give the same verdict. SM268 C1 decides
whether local is honoured at all.

# Fix shape

One rule for `local` in one place, chosen by SM268 C1; the six blocks
then collapse into `_authorise_manage` (review item TO-9), which is
blocked until this is decided.
