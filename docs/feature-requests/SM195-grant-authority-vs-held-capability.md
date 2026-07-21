---
title: "SM195 - Grant authority distinct from held capability"
subtitle: "A grantor can only confer capabilities they hold - so a sub-admin must carry mcp themselves just to grant it to their AI, enlarging their own surface for a purely administrative reason. Separate 'may confer X' from 'holds X'."
brand: plain
status: candidate
status-note: "further-consideration request 2026-07-21. The delegate_sub_user_creation capability is the existing precedent for exactly this split; this generalises it. Security-sensitive - the escalation guard must be preserved."
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
