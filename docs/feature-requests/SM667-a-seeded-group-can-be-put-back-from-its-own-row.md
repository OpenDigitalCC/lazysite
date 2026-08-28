---
title: "SM667: a seeded group can be put back to its shipped permissions from its own row"
subtitle: "Release manager, 2026-08-28: 'working with groups, what would be really useful in the groups panel, for seeded groups, is set permissions to default'"
brand: plain
standard-margins: true
status: candidate
---

# What is missing

SM644 shipped `reset-groups`, which restores the seeded groups to their shipped
capability rows, grantable lists and nesting. It is a CLI command and it works
on ALL seeded groups at once.

Both of those are wrong for the case an operator actually hits. They are looking
at one group in the Groups panel, they can see its row has drifted, and the
remedy is a shell they may not have on a host they may not reach - and when they
get there it resets nine groups to fix one.

# What it should be

An action on the row of any group carrying the `seeded` marker (SM608), which is
already how the panel tells an engine-shipped group from one made here. Not
offered at all on a group an operator made: there is no shipped default to
return to, and offering it would imply there was.

The behaviour follows SM644's decisions rather than reopening them:

Membership is preserved
: SM644's rule, and more important here - membership of the manager group is
  what identifies the administrators, and a reset that emptied it could lock
  every human out of the instance it was run on.

It shows what will change before it changes it
: `reset-groups` is dry-run unless `--apply`. The panel equivalent is that the
  action opens with the diff - these capabilities go on, these go off, grantable
  becomes this - and the operator confirms that, not a generic warning. An
  operator who can see that the only change is `housekeeping` going off will
  press it; one shown "Reset this group?" will not, and will go and ask.

Accounts are never touched
: Also SM644's.

# Where the work actually is

The capability rows are the easy half. `_default_group_seed()` already computes
the shipped state and `cmd_reset_groups` already diffs against it, so the panel
needs a per-group view of a computation the tool performs today.

The half to be careful about is that the reset must go through the same
authority checks as editing the row by hand. A reset is a conferral: it can turn
capabilities ON, and SM195's ceiling says an actor may confer only what it holds
or has `grantable` for. A reset that bypasses `_may_confer` because "it is only
restoring the default" is a privilege escalation with a reassuring name - the
default is not automatically within the resetting actor's authority.

So the refusal case has to be designed, not discovered: a sysop with authority
over the whole row resets it; an actor without authority over one capability in
it is told which capability, and nothing is written. Partial application would
be worse than refusal, because a half-reset row is neither the default nor what
the operator had.

# Open

1. Is this offered per-group only, or is there also a panel-level "reset all
   seeded groups" that mirrors the CLI? Per-group is what was asked for; the
   all-groups version is `reset-groups` and may be better left in the CLI where
   its blast radius is visible.
2. Does the diff show nesting and `grantable` changes as well as the capability
   row? The CLI resets all three. Showing only the checkboxes would make the
   panel's account of the change incomplete.

# Related

[[SM644]] (the CLI this surfaces, and whose decisions it inherits), [[SM608]]
(the `seeded` marker that decides whether the action appears), SM195 (the
conferral ceiling this must not bypass), [[SM496]] (never-decided versus
declined, which the diff has to distinguish).

# Not started
