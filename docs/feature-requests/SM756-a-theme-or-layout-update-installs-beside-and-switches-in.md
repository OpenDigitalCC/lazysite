---
id: SM756
title: "SM756: an update to the theme or layout being served installs beside it and switches in - nothing writes into an active artefact, on any surface"
subtitle: "The release manager's ruling, 2026-09-05: 'what we want is atomic theme/layout changes, so nothing works on an active theme or layout, they load new and switch in. it should be atomic, and common on all surfaces.' SM749 closed the file-write surfaces; two whole-artefact paths still write in place over the active one, and this filing takes them."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-05 on claude/sm756-update-installs-beside-and-switches for 0.13.1. Themes::_swap_in is the switch: the staged directory is a sibling of its target, the old directory steps aside by rename and the staged one takes its name by rename; the old is KEPT under the snapshot name when a snapshot is wanted (_snapshot_wanted, the SM176 rule split from the copy) and removed otherwise, so the snapshot is the previous directory itself. Used by the theme update (_install_theme_from_dir, per layout), the layout force-update (_install_layout_from_dir: the staging copy is the current layout with themes/ and all, the release laid over it), and the asset mirror the browsers fetch from (_mirror_theme_assets, docroot and every content root - which also means content-root mirrors now carry theme-tokens.css, which they never had). One path for active and non-active alike: the earlier sentence below about a non-active artefact keeping the in-place update is superseded - one code path is simpler and the switch costs nothing. t/unit/manager/155 holds: the served directory's inode changes exactly once, the old directory is untouched until it steps aside (instrumented at the switch), the snapshot is the old inode, themes travel with a layout update, no staging is left behind, and no cp-over-the-served-directory remains in either module."
---

# The ruling

> what we want is atomic theme/layout changes, so nothing works on an active
> theme or layout, they load new and switch in. it should be atomic, and common
> on all surfaces.

# What SM749 closed, and what it left

SM749 made the theme and layout being served read-only to every FILE write -
save, binary save, delete, mkdir, move, copy - through the choke point and the
DAV stack, and gave the workflow its first verb (`copy_theme`). Its filing
recorded one asymmetry for decision, and the decision is now taken.

Two whole-artefact paths still write in place over the active artefact:

| Path | Where | What it does today |
| --- | --- | --- |
| theme upload with `update: true` | `Themes::_install_theme_from_dir` | snapshots the existing theme (SM176), then `cp -r` over it - including the active one (the SM365 fix, so a layout release and its theme update together) |
| layout install with `force` | `Layouts::_install_layout_from_dir` | snapshots the existing layout, then `cp -r` over it - including the active one |

Both are better than a file write - a snapshot exists, the copy is one
operation - and neither is atomic: `cp -r` into the directory being rendered is
a sequence of file replacements, and a request between two of them renders half
of each. The activation path IS atomic: the pointer moves once, the mirror is
rebuilt once, the cache clears once.

# What is asked for

**An update to the active artefact never writes into it.** It installs the new
version BESIDE the active one and switches the pointer:

1. Install into a staging name derived from the target (`<name>.<stamp>` or
   `<name>-next`), exactly as a fresh install does.
2. Build the mirror for the staging name (what activation does).
3. Rename the active directory to a snapshot name and the staging directory to
   the target name - two `rename(2)`s inside the same filesystem, or, where the
   pointer can name the staging directory directly, one pointer write - then
   clear the cache. The site serves the old artefact until the switch and the
   new one after it, and nothing in between.
4. The snapshot is the rollback, as today.

**Common on all surfaces**: `theme-upload`, `layout-install`, `layouts-install`,
the manager's upload and install buttons, and MCP `install_layout` all route
through the two `_install_*_from_dir` functions, so the change is in two places
and every surface inherits it - the same shape SM748 and SM749 argued for.

**One path for active and non-active alike** (decided in the build): the switch
costs nothing, and one code path is simpler than a branch on whether anything
is rendering the directory.

# What to hold

- A theme upload with `update: true` against the active theme leaves the served
  files byte-identical until the switch, and the new files after it, with no
  request able to see a mix - asserted by a reader racing the update (or, in a
  unit, by checking the active directory's inode changes exactly once).
- The snapshot exists and is the previous content.
- The mirror and cache are rebuilt once, at the switch.
- The same for a layout `force` install.
- The two functions are the only writers into `lazysite/layouts/<active>`; a
  lint in the t/lint/114 family can hold that no other code path `cp`s or opens
  for write under the active pointer.

# Related

SM749 (file writes, the copy verb, the choke-point rule), SM365 (why the theme
half of an update writes in place today), SM176 (the pristine baseline and the
snapshot), SM222 (the vocabulary for "switching").
