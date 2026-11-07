---
id: SM1400
title: "SM1400: a layout's backup snapshot is not a layout"
subtitle: "Triage T-87: after delete_layout the snapshot it keeps, <name>-backup-<stamp>, was listed as a layout with the deleted layout's theme under it, and a second delete removed it. Every listing door now lists a snapshot as a backup and never as a layout or a theme."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "0.16.7 edge triage, T-87"
area: themes
status-note: "SHIPPED (PENDING) on n771: Manager::Themes::action_themes_list_all leaves every -backup- directory (a layout's or a theme's) out of `themes` and lists it under `backups` {artifact, layout, name, path}; the Appearance page's Backups panel draws that list; MCP list_themes and the control API answer with the same listing. t/unit/manager/476."
---

# What happened

`delete_layout` keeps a recovery snapshot, `lazysite/layouts/<name>-backup-<stamp>`
(pruned by `backup_retention`), and an activate leaves one of an edited layout
the same way. `layouts-available` and the catalogue's installed annotation left
those directories out (`08-layout-delete.t` pinned that), but the listing the
Appearance page, MCP `list_themes` and the control API's `themes-list-all` all
read from (`Manager::Themes::action_themes_list_all`) walked every directory
under `layouts/` and reported each theme under it with the directory's name as
its layout. So after a delete the snapshot was drawn as an installed layout,
with the deleted layout's theme under it, and the operator's second delete
removed the snapshot that was the point of the first.

# What was built

- `action_themes_list_all` skips a `-backup-<stamp>` layout directory and a
  `-backup-<stamp>` theme directory in the `themes` rows, and returns them in a
  new `backups` list: `{ artifact: layout|theme, layout, name, path }`, `layout`
  being the base name for a layout snapshot and the enclosing layout for a
  theme's, `path` the `lazysite/layouts/...` path `artifact-backups-delete`
  already takes.
- The Appearance page keeps the server's `backups` and seeds its collapsed
  Backups panel from them, so a layout snapshot sits beside the theme snapshots
  the page already folded there, with the same per-item and purge buttons.
- `/docs/ai-connector-tools` (`list_themes`) says so.

Not a behaviour change to the snapshot itself: it is still made, pruned and
restorable as before.

Test: `t/unit/manager/476` - after a delete, no `themes` row names the snapshot
as its layout or is a theme snapshot; both snapshots are under `backups` with
the path that deletes them; `layouts-available` is unchanged; the page reads
`backups` and MCP `list_themes` is this listing. Fails with the listing and the
page reverted.
