---
title: "SM150 - Manager polish: click-to-configure, no group-edit reloads, wording"
subtitle: "Second demo-review polish round on Users/Groups"
brand: plain
status: shipped
status-note: "delivered 2026-07-12; name click opens the editor (consistent for parents/leaves), accent expand triangle, in-place group-edit updates (capability toggles + members), operator->administrator in permission messages"
---

# SM150 - Manager polish round 2

From the demo review, on top of SM149.

- **Users tree interaction.** Clicking an account **name** opens its editor -
  consistent for top-level accounts and sub-accounts (a leaf name did nothing
  before). The accent disclosure **triangle** is the obvious control to expand a
  sub-tree; the explicit Configure button stays, de-emphasised. The name click
  stops propagation so it never toggles a parent's sub-tree.
- **No group-edit reloads.** Editing a group used to call the full
  `renderGroups()` on every capability toggle, reloading and collapsing the
  whole list. Now a capability toggle or a member change updates just that
  group's summary (counts, manager badge) and pills in place
  (`groupSummaryInner` / `refreshGroupSummary` / `refreshGroupMembers`).
- **Clearer wording.** Permission-denied messages say "an **administrator** can
  grant it on the Groups page" instead of "an operator" (audit trail, sessions &
  keys, notifications) - clearer to the person actually reading it.
