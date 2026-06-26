---
title: "SM104 - clarity: top-level accounts vs sub-users"
subtitle: "Make the account hierarchy legible, and stop the 'under the manager' confusion"
brand: plain
---

::: widebox
Accounts the operator creates are **top-level** (no parent); **sub-users** are accounts
a partner with `create_sub_users` made under itself (`created_by` points at the
partner), and those nest. The Add-user form's old default - "(top level - under you,
the manager)" - read as if it nested the account under a "manager", but it produces a
top-level account, so operator-created accounts all appear as siblings with nothing
to nest under. Result: "I made manager sub-users but they're top-level." Need the
distinction shown plainly.
:::

## Why it happens

- The manager is an **operator** (full access by group membership), not a partner with
  the `create_sub_users` capability, so it is not offered as a parent in the Add-user
  dropdown - every operator-created account is top-level by construction.
- Sub-user nesting (shipped) only nests an account whose `created_by`/`managed_by` is
  another **listed** account; a top-level account has neither, so it renders at the
  root - correctly, but indistinguishably from a "should have been nested" one.

## Fixes

1. **Reword the parent dropdown** (done): "(top-level account - no parent; managed by
   you)" instead of "under you, the manager".
2. **Label each row** explicitly: a top-level account carries a quiet "top-level" tag;
   a sub-user carries "sub-user of <parent>" in its summary (in addition to the visual
   nesting), so the two are unambiguous even at a glance.
3. **Optional - a manager/site root**: render all top-level accounts under a single
   collapsible "Site accounts (managed by you)" node, so the tree has the one root the
   operator expects, with delegated sub-users nested beneath their partner parents.
4. **Optional - allow nesting under the operator**: let the Add-user form create an
   account whose `created_by` is the operator, so it genuinely nests under a manager
   node (needs the manager to be a selectable parent).

## Status

Queued (item 1 shipped with SM100). Items 2-4 are bounded `users.md` rendering +
a small Add-user parent-option change; item 3/4 decide whether "top-level" should
visually live under a manager root or stay flat - a quick design call.
