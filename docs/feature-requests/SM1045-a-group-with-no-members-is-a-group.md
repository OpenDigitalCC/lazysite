---
id: SM1045
title: "SM1045: a group with no members is a group"
subtitle: "acl-set called a group created on the Groups page unknown until someone was in it, because the known-group set was built from membership alone."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox report 2026-10-12, sites.lazysite.io (engine 0.15.4)
area: security
status-note: "SHIPPED (PENDING): group_names() is the union of groups-settings.json and the groups file; a name in neither is still unknown. acl-set's store-empty guard still reads accounts and membership (groups_with_members). t/unit/auth/50, t/unit/manager/300."
---

# What was wrong

`Lazysite::Auth::Settings::group_names()` returned the groups named in the
groups file, which lists a group only once it has a member. The Groups page
creates a group as a record in `groups-settings.json`. A group created there
and not yet given anyone was therefore "no group with that name" to `acl-set`:
it was listed under `unknown`, and a read or write list naming only such groups
was refused as naming nobody (SM901). Adding a member cleared it.

Reported on sites.lazysite.io: `editors`, `category-managers`, `commenters`,
`account-approvers` and `feedback-readers`, each unknown until it had a member.

# The fix

`group_names()` returns the union of the groups in `groups-settings.json` and
the groups in the membership file. That is the definition the module already
used for nesting (`_group_closure_in`'s `%is_group`) and the users tool uses
for `group-create` and `group-nest`. A name in neither store is still reported
unknown, and a list naming only such names is still refused.

`acl-set` skips the check on a site that keeps no principals of its own (SM901,
SM912 P4: no accounts and no groups). That guard keeps its meaning: it now asks
`groups_with_members()`, the membership file alone, because
`groups-settings.json` is seeded with the shipped groups on every site the users
tool has run on, and a seeded record is no evidence that the site keeps
principals. Read through the union, the guard would have started checking, and
refusing, rules on a site authenticated by an upstream proxy (t/unit/manager/15
measured that before the guard was kept).

# Inventory: who asks "does this group exist"

| Ref | Where | Reads | After SM1045 |
|---|---|---|---|
| I-1 | `Lazysite::Manager::Files::action_acl_set` (control API `acl-set`, MCP `set_permissions`, `lazysite acl set`) | `group_names()` | union - the fix |
| I-2 | `Lazysite::Auth::Settings::_group_closure_in` | own union of both stores | unchanged, agrees |
| I-3 | `lazysite-processor/acl.pm` group walk | own union of both stores | unchanged, agrees |
| I-4 | users tool `cmd_group_create`, `cmd_group_nest` | `$gs->{$g} \|\| $members{$g}` | unchanged, agrees |
| I-5 | users tool `cmd_group_reset` | settings record only | unchanged: it resets a record, so "no record" is the right refusal |
| I-6 | users tool `cmd_group_remove` ("Group not found") | membership only | unchanged: removing a member from a group with no members has nothing to remove |
| I-7 | n433 (SM1016, unlanded) `Domains::_refuse_unknown_names` | `group_names()` plus keys of `read_group_settings()` | agrees; the second half is now redundant and can be dropped for `group_names()` alone |

The users tool's `group-add` (a member into a group) checks no existence: it
creates the membership line, which is how a group with no record comes to be.

# Tests

- t/unit/auth/50: a record with no members, members with no record, both, and
  neither; either store absent; no auth directory.
- t/unit/manager/300: the reported five groups in one read list are accepted
  with nothing unknown and no warning; one empty group beside a populated one;
  `@editers` beside `@editors` is named unknown, and alone is refused; a site
  whose only group store is the seeded settings stays unchecked.

Both fail on main (auth/50: 3 of 8; manager/300: 3 of 4). Sabotaged three ways
(tmp/n510-repro-and-sabotage.sh, restored by cp, cmp clean): main's
`group_names`; the settings store dropped from the union; the guard reading the
union. Each fails.

# Related

[[SM901]], [[SM912]], [[SM1016]], [[SM1046]].
