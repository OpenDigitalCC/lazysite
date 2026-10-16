---
id: SM1086
title: "SM1086: an operator may add someone to the operator group"
subtitle: "The conferring ceiling counts the operator flag as held by the operator, so a sysops member can put someone in sysops from the manager."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: auth
status-note: "SHIPPED on n599: tools/lazysite-users.pl _may_confer; t/unit/users/51."
---

# What happened

The release manager on edge (0.15.5), signed in as a member of sysops, tried
to add an account to sysops and got:

    You cannot add anyone to 'sysops': it grants 'manager', which you may
    not confer. A sysop can allow it on the Groups page: open your group and
    add 'manager' to the capabilities it may confer.

The ceiling (SM268 H8) lets an actor confer what it holds. The operator flag,
`manager`, is a group flag and not one of `@CAP_KEYS`. So `caps_for` never
reports it, while the granted side (`_caps_granted_by_group_attributed`)
counts it. "Holds it" could never be true of `manager`, so no signed-in
account could add anyone to the operator group, the operator included. This
predates 0.15.5, and was reproduced on a fresh site with the setup-sysop
account.

The message's remedy, `grantable-add manager`, would have let every member of
the named group make operators.

# What shipped

`_may_confer` treats `manager` as held by an account in the operator group
(`account_is_operator`). Nothing else changes:

- An operator adds an account to the operator group.
- An account with `manage_users` and grant authority over every other
  capability is still refused, and the refusal names `manager` (SM991).

t/unit/users/51.
