---
title: "SM149 - Plugin surface + Users/Groups polish"
subtitle: "Plugin Manager rows, hidden/unlisted plugins, one picker, in-place updates"
brand: plain
status: shipped
status-note: "delivered 2026-07-12 from the demo review; Plugin Manager row redesign, hidden/unlisted plugin flags, remote-sync gate, Users General card + hierarchy reassign + URL-carried editor, one pill picker for members + add-user groups, in-place member updates, delete-group-when-empty, theme snapshot only on change"
---

# SM149 - Plugin surface + Users/Groups polish

Field-review round on the running demo.

## Plugin surface

- **Plugin Manager rows** redesigned: a fixed control column (the enable toggle
  with **Configure** stacked beneath it - enabling no longer shifts the row
  across a column), name+description, and an end column carrying the **core**
  badge or an **ⓘ info tooltip** (the script path lives there, not inline).
- Two descriptor flags, honoured by the manager:
  - `hidden` on an action - a lifecycle hook driven by the enable/disable
    toggle, not a config button. Content history's enable/disable and the Stats
    `refresh` are hidden (so no "Enable" while enabled, no pointless Refresh).
  - `unlisted` on a plugin - it ships and works but is not a Plugin-Manager
    toggle. The **payment demo** (hidden until a real payment integration
    exists; the 402 helper/docs/tests stay) and **Logging & forwarding** (an
    operator/CLI concern, configured via lazysite.conf) are unlisted.
- **Remote sync**: "Test connection" is gated with `needs: remote_url` - it
  refuses until a remote is configured instead of testing against nothing.

## Users / Groups

- Editor card order: **General** (Type, Note, Email) first, then Credentials,
  Groups, Capabilities, **Account configuration**, Danger zone.
- "Move under" (reassign parent) lists targets in **tree order, indented**.
- The open account is carried in the URL (`?user=`), so a full browser refresh
  reopens its editor.
- **One pick-none-or-many control** (pills + type-and-add) for BOTH group
  members and the add-user group picker (was a select-box vs pills).
- Adding/removing a group member updates **in place** (just that group's pills),
  not a full page reload.
- **Delete group** is refused while it has members (UI hides it; backend
  refuses) - deleting a non-empty group would strip members' permissions.

## Appearance

- Trying a theme on/off only takes a backup when the artifact actually changed
  since its last snapshot - exploring no longer spawns identical backups
  (`_snapshot_artifact` compares digests; excludes the source when it is itself
  a backup dir).
