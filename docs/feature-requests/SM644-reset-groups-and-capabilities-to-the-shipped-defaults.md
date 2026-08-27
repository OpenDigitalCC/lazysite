---
title: "SM644: a site's groups and capabilities drift under workarounds, and there is no way to put them back"
subtitle: "Operator, 2026-08-27: 'most sites have few users, maybe one or two, and likely caps are muddled owing to workarounds when problems occur... we could reset all to default, then users just need to be added to new groups, this is safest as current position is likely overgranting'"
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT as `lazysite-users.pl reset-groups [--apply]`. SEEDED groups go back to the shipped defaults - capability rows, grantable, nesting and membership; groups an operator MADE are untouched, record and members, so the organisational group named in a protected area's ACL keeps working; ACCOUNTS are never touched. The `seeded` marker (SM608) decides, which is what makes this safe to state rather than to judge. THE LOCKOUT DEFENCE IS THE RELEASE MANAGER'S, and it is better than the flag I proposed: membership of the full-access group IDENTIFIES the administrators, so that group keeps its members and the answer to \"who can get in afterwards\" is already in the store. There is no state in which nobody can reach the manager, so no --admin argument is needed. DRY RUN IS THE DEFAULT and --apply is required to write: \"likely over-granting\" is a belief until an operator reads what would actually change. THE FIRST VERSION UNDER-REPORTED THE DRY RUN, which matters more here than anywhere else because the dry run IS the safety mechanism: it walked the settings file alone, so a group with MEMBERS and no settings record - which group-create plus group-add produces - was reported as \"0 operator groups untouched\" while it sat there with a member in it. It walks the union now, and the test constructs that exact shape. Four sabotages, all fail. The audit-completeness gate caught the new command unregistered, which is that gate doing its job."
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
