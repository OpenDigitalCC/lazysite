---
title: "SM194 - Promote a sub-user to top level"
subtitle: "account-reassign can only move a user to another EXISTING parent, never to top level; a user who becomes independent is stuck under someone. Allow promotion - operator-only, and honest about the immutable created_by scope ceiling."
brand: plain
status: candidate
status-note: "field request 2026-07-21. Cheap for the management tree (managed_by); the created_by scope ceiling is the deliberate conflict this write-up resolves."
---

# SM194 - Promote a sub-user to top level

## Why

The SM071 sub-user model gives every account two parent relationships:

managed_by
: the MUTABLE delegation / audit parent - who currently manages the account.
  `account-reassign USER --to NEWPARENT` moves it (and the sub-tree follows).

created_by
: the IMMUTABLE provenance - who originally created the account. It never
  changes, and it also carries the SCOPE CEILING: `resolve_user_scopes`
  (`Lazysite::Auth::Settings`) intersects a user's content-root scope with every
  ancestor's scope up the created_by chain, at resolve time, so config drift can
  never lift the ceiling.

Field need: a user who leaves a team, or becomes independent, cannot be moved to
top level. `cmd_account_reassign` requires `--to NEWPARENT` and dies with "New
parent not found" for an empty target - there is no "to none". So once a user is
under someone they stay under someone. This should be possible.

## The conflict to be explicit about

"Move to top level" means two different things, and only the first is
unconditionally safe:

1. Top of the MANAGEMENT tree (managed_by = none). Purely delegation / audit
   provenance. Making an account independently managed has no security
   consequence - it is the natural agency operation (a member leaves a team).
2. Top of the SCOPE tree (unconfined by the creator). This collides with the
   deliberate design: the created_by chain ceiling exists precisely so a
   delegated sub-user can NEVER be lifted above the confinement of whoever
   created them. Crucially, clearing managed_by does NOT lift this - the resolver
   walks created_by, not managed_by - so a "promoted" user can still be
   scope-capped by their original creator. Operators must not be surprised by
   that.

## Design

Separate the two so each is a deliberate choice:

1. Management promotion (the ask). Allow `account-reassign USER --to ''` (or a
   clearer `account-promote USER` verb) to clear managed_by, making the account
   top-level-managed. Keep the existing self / cycle guards; top level has no
   cycle risk.

2. Operator-only. Promotion must be gated on a full operator (manage_users), NOT
   available to a mid-tree delegate. This is the "unless something conflicts"
   guard: a delegate promoting their own child out from under themselves would
   defeat the confinement spine. `_authorise_manage` already gates reassignment
   to the actor's own sub-tree; promotion to top level needs the stricter
   operator check.

3. Scope emancipation - explicit, separate, optional. If an operator also wants
   the account genuinely unconfined by its creator, add an explicit,
   operator-audited flag (e.g. `scope_independent: 1`) that `resolve_user_scopes`
   honours by stopping its walk at that user. Do NOT rewrite created_by - that is
   immutable provenance and audit integrity depends on it. Keeping emancipation a
   distinct, logged step means "who manages them" and "what they can reach" stay
   two separate decisions, and the default promotion changes only the former.

## Tests

- `account-promote` (or `--to ''`) clears managed_by; the account is then
  top-level in `account-tree`.
- A promoted user WITHOUT scope_independent is still scope-capped by created_by
  (asserts the deliberate ceiling survives management promotion).
- With scope_independent set by an operator, `resolve_user_scopes` stops walking
  the created_by chain for that user.
- A non-operator delegate is refused promotion (operator-only guard).

Related: SM071 Phase 2 (sub-user provenance, `created_by` / `managed_by`,
`account-reassign`), `resolve_user_scopes` (the created_by scope ceiling), SM154 /
SM155 (domain-scope confinement), and `_authorise_manage`.
