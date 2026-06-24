---
title: "SM077 - File-manager UI improvements + graphical ACL panel"
subtitle: "A per-file permissions panel and further Files-page UX"
brand: plain
---

::: widebox
A graphical **permissions panel** on the Files page - set a file's owner and
its read/write allowlists with checkboxes over the managed users and groups,
instead of hand-editing the `.acl` JSON - plus the next round of Files-page
usability. This is the deferred SM074 "graphical permissions panel" promoted
to its own item.
:::

## Status

Queued - not yet specced. The enforcement (SM074 central ACL store + the
`acl-set`/`get`/`remove` actions) already ships; this is the UI over it.

## Scope

- **Per-file Permissions panel.** A control on each file row / editor that
  shows the current `owner` and `read`/`write` lists and lets the operator (or
  owner) edit them as **selectable lists of managed users** (and groups, once
  group ACLs land - the SM074 `@group` deferral), calling `acl-set` /
  `acl-remove`. Replaces editing `<file>.acl`-equivalent raw JSON.
- **Owner display** is already on the Files page (SM074); this adds the *edit*
  surface and a clear "owned by you / others / unrestricted" state.
- **Further Files-page UX** (gather and prioritise): inline rename / move;
  a lock indicator (tie-in to the editor↔WebDAV lock model); a generated-cache
  bulk-purge using the existing list-by-type; a brief-presence filter; richer
  type/owner columns.

## Considerations

- **Data the panel needs:** the list of managed users/groups (a users-list or
  `whoami`-style endpoint scoped to what the actor may assign), and the current
  ACL (`acl-get`). Operator sees all; an owner edits only their own files.
- **Group ACLs:** the panel is the natural driver for finishing the `@group`
  ACL entries deferred in SM074 - design them together.
- **Keeps enforcement server-side:** the panel only calls the existing actions;
  no new authority. Operator-vs-owner editing follows the same `_is_operator` /
  owner rules already enforced.

## Dependencies / related

SM074 (per-file ACLs - the store + actions), the lock-propagation work
(editor↔WebDAV), and the agent-introspection surface (for the assignable
user/group list).
