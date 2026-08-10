---
title: "SM195 - Grant authority distinct from held capability"
subtitle: "A grantor can only confer capabilities they hold - so a sub-admin must carry mcp themselves just to grant it to their AI, enlarging their own surface for a purely administrative reason. Separate 'may confer X' from 'holds X'."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-09 (unreleased on main), and the filing's PREMISE WAS WRONG in a way that changed the work. It opens "the delegation model enforces privilege de-escalation: a grantor can only confer capabilities they themselves hold" and asks to relax that. There was no such ceiling: %ACTOR_FORBIDDEN required manage_users and nothing more, so a non-operator delegate could confer ANY capability - including on a group it belonged to. Reproduced before building: a subadmin holding only manage_users granted itself mcp, and the write succeeded. So option 1 (a per-group `grantable` set) is built AND the ceiling it is an exception to is built with it, because grantable is meaningless without a rule to except. Now: a non-operator may confer C only if they hold C or C is in their groups' grantable set; removing a capability needs no authority (de-escalation); setting grantable is OPERATOR-ONLY, which is what preserves the invariant this filing names as non-negotiable - grant authority is conferred from above, never self-assumed; the manager flag is operator-only for the same reason. The manager API now passes the actor for group-settings-set, without which the ceiling silently would not apply. BEHAVIOUR CHANGE ON UPGRADE: delegates that relied on unbounded conferral will be refused, with a message naming the group-set command that restores it deliberately. t/unit/users/23 covers the ceiling, the exception, self-assumption, de-escalation, unknown capabilities and the operator bypass."
---

# SM195 - Grant authority distinct from held capability

## Why

The delegation model enforces privilege de-escalation: a grantor can only confer
capabilities they themselves hold. That is the right default - it stops a curious
or compromised sub-admin from minting themselves, or an agent, a capability they
were never trusted with.

But it conflates two different things - EXERCISING a capability and CONFERRING it.
The cost shows up in the common agency setup: to grant their AI the `mcp`
capability (issue a token / set the agent group's caps), a sub-admin must hold
`mcp` on their OWN account - even if they never want to drive MCP themselves. So a
purely administrative act (delegating to an agent) forces the sub-admin to carry a
live capability they do not want, enlarging their own account's attack surface for
no functional reason. That is backwards: the least-privilege thing is for the
sub-admin to be able to grant `mcp` to the agent WITHOUT holding `mcp`.

## The precedent already in the model

This split already exists for one capability:

create_sub_users
: exercise - create sub-accounts under yourself.

delegate_sub_user_creation
: confer - let your sub-accounts create THEIR own sub-users, without that being
  about your own creation right.

`delegate_sub_user_creation` is "may confer, distinct from exercises". SM195 is
the same idea generalised to capabilities at large (`mcp`, `api`,
`read_submissions`, ...).

## Built 2026-08-09 - and the premise above was wrong

**There was no ceiling to relax.** The "Why" section opens by describing
privilege de-escalation as an existing default that costs a sub-admin a live
capability. Checked against the code and then reproduced: `%ACTOR_FORBIDDEN`
required `manage_users` and nothing further, after which a non-operator delegate
could confer **any** capability - including on a group it was itself a member of.

The reproduction, before any code was written: a `subadmin` account whose only
capability was `manage_users` conferred `mcp` on another group, and then on its
own group. Both returned `{"ok":1}`. A `manage_users` delegate could grant itself
`mcp`, `api` or `manage_config` and become an operator in all but name.

So the cost this filing describes was not real - a sub-admin never had to hold
`mcp` to grant it - and a different, worse problem was. Option 1 is built, and
**the rule it is an exception to is built with it**, because a `grantable` set
that excepts nothing is decoration.

What now holds:

- a non-operator may confer `C` only if they **hold** `C`, or `C` is in the
  `grantable` set of one of their groups;
- **removing** a capability is always allowed - de-escalation needs no authority;
- `grantable` is **operator-only**, which is what preserves the invariant below;
- the `manager` group flag is operator-only for the same reason: a delegate that
  could mint a manager group would not need any other escalation.

The manager API now passes the actor for `group-settings-set`. Without that the
tool saw no actor and the ceiling did not apply - which is precisely how the
original hole survived: the check existed one layer up and only asked for
`manage_users`.

**This changes behaviour on upgrade.** A delegate that relied on unbounded
conferral is now refused, and the refusal names the `group-set ... grantable`
command that restores the ability deliberately. That is the intended direction:
the previous behaviour was a privilege-escalation path, not a feature.

## The invariant that must survive

Whatever the design, it must NOT reopen self-escalation: grant authority is
conferred from ABOVE, never self-assumed. A sub-admin may confer `mcp` only
because an operator explicitly gave them the authority to; a sub-admin can never
invent grant authority for a capability the operator never delegated. The ceiling
still holds one level up - we are moving WHERE the trust is expressed (an explicit,
operator-set grant right) not removing it.

## Design options

1. A per-group grantable set (recommended). Alongside a group's held caps, store a
   `grantable` set - the capabilities that group may confer on its sub-tree
   WITHOUT holding them. The grant check becomes: a grantor may confer cap C if
   C is in its held caps OR in its grantable set. Reuses the group-settings
   storage the SM155 scope binding uses; generalises cleanly; one mechanism for
   all caps. The grantable set is itself capped by what the operator conferred, so
   the invariant holds. Optionally, onward delegation (may a sub-admin pass the
   grant authority further down?) is a separate flag, mirroring
   create/delegate_sub_user_creation.

2. Per-capability delegate_<cap> companions. Add `delegate_mcp`,
   `delegate_api`, ... alongside each delegable capability, exactly like
   `delegate_sub_user_creation`. Most explicit and most auditable, but
   proliferates capabilities (two per delegable cap) and bloats the Groups UI.

3. An operator-designated sub-admin role. Mark a group as an administrative
   delegate whose grant authority is a configured allow-list decoupled from what
   it holds. Effectively option 1 with a role wrapper; heavier, less granular.

Recommendation: option 1 - a `grantable` set per group - as the smallest general
change that removes the forced-to-hold surface while keeping the escalation guard,
with option 2's `delegate_sub_user_creation` retained as the already-shipped
special case (or folded into the general set).

## What to work through in the consideration

- Token issuance: a token's caps should be capped by (issuer held caps UNION
  issuer grantable caps), not held caps alone.
- UI: the Groups page needs to show "may grant" separately from "holds", or an
  operator will not understand why a sub-admin without `mcp` can still hand it to
  an agent.
- Audit: conferring a capability you do not hold is exactly the event an auditor
  wants to see - log grantor, cap, grantee, and the grant-authority basis.
- Does `read_submissions` / `feedback` (least-privilege agent grants) want the
  same treatment, or are they low-risk enough to leave under hold-to-grant?

Related: `delegate_sub_user_creation` / `create_sub_users`
(`Lazysite::Capabilities`), the grant authorisation (`_authorise_manage` and the
cap-grant path in `tools/lazysite-users.pl`), SM155 (group-level binding storage),
and SM180 (capability/dependent-service coherence).
