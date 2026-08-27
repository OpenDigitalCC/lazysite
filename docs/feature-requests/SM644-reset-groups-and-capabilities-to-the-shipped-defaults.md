---
title: "SM644: a site's groups and capabilities drift under workarounds, and there is no way to put them back"
subtitle: "Operator, 2026-08-27: 'most sites have few users, maybe one or two, and likely caps are muddled owing to workarounds when problems occur... we could reset all to default, then users just need to be added to new groups, this is safest as current position is likely overgranting'"
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-08-27 by the operator. When access does not work, the fix under time pressure is to grant something - and the grant outlives the problem. Across seventeen production sites the operator's own read is that capability sets are now muddled and the drift runs one way: TOWARDS over-granting, because nobody ever removes a capability to fix an outage. SM631 then reorganised groups into bundles and roles, so the shipped shape and what is actually on those sites have diverged twice over. THE ASK: a CLI reset that puts groups and capabilities back to the shipped defaults, after which the operator adds one account to the admin group and reconfigures the rest from the manager UI. THE ARGUMENT FOR RESET OVER RECONCILE, and it is the operator's: on a site with one or two accounts, re-adding people to groups is minutes of work, while auditing which of the accumulated grants were ever deliberate is not possible at all - nothing records WHY a capability was granted. A reset is the only operation that reaches a known state. THE DANGER IS OBVIOUS AND MUST BE DESIGNED FOR: this removes access, on live sites, and a reset that leaves nobody able to reach the manager is an outage the manager cannot fix. It must refuse to run unless it can name the account that will still hold admin afterwards, and it must say exactly what it is about to remove before it removes it."
---

# Why the drift only goes one way

Nothing in the product records why a capability was granted. When a partner
cannot publish, the fix that works is to add a capability; when it works, the
ticket closes. The capability stays. Repeat that across a year and seventeen
sites and the result is not random drift - it is monotonic over-granting.

That is also why reconciliation is not available as an option. To reconcile you
would have to know which grants were deliberate, and nothing knows.

# What makes reset cheap here specifically

| | |
|---|---|
| Accounts per site | one or two, typically |
| Cost of re-adding them to groups | minutes |
| Cost of auditing accumulated grants | not possible - no record of intent |

The asymmetry is the whole argument. On a site with fifty accounts this would
be an unreasonable instrument; on these sites it is the cheap one.

# The shape

A CLI command that restores the seeded groups, their capability rows, their
nesting and their `grantable` sets to what `_default_group_seed` and
`_default_group_nesting` describe - the same shape a freshly set-up site gets.

Group MEMBERSHIP is the question the design turns on. Wiping it is what makes
the reset complete and what makes it dangerous; keeping it preserves exactly
the assignments most likely to be part of the muddle. The operator's
description - "then users just need to be added to new groups... maybe just one
user needs to be added to admins group, to reconfigure the rest from the UI" -
describes membership being cleared, with one account put back by hand.

# What it must refuse to do

**It must not be able to lock the operator out.** A reset that leaves no
account holding manager access turns a permissions problem into an outage that
the manager UI cannot repair, on a live site, with no way back except a shell
the operator may not have.

So it must name the account that will hold admin afterwards, and refuse to run
without one. Not a flag that suppresses a warning - a required answer to "who
is the operator on this site when this finishes".

**It must show the removal before making it.** A dry run that lists every
account whose access is about to change, and every capability about to be
dropped, is what turns "likely over-granting" from a belief into something the
operator can read before acting on it.

**It must be one site at a time.** Seventeen sites in one command is seventeen
outages if the design is wrong once.
