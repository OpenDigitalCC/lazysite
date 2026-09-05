---
id: SM756
title: "SM756: an update to the theme or layout being served installs beside it and switches in - nothing writes into an active artefact, on any surface"
subtitle: "The release manager's ruling, 2026-09-05: 'what we want is atomic theme/layout changes, so nothing works on an active theme or layout, they load new and switch in. it should be atomic, and common on all surfaces.' SM749 closed the file-write surfaces; two whole-artefact paths still write in place over the active one, and this filing takes them."
brand: plain
standard-margins: true
status: candidate
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

**A non-active artefact keeps the in-place update.** Nothing is rendering it;
the atomicity argument does not apply, and the snapshot still protects an edit.

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
