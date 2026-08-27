---
title: "SM544: the safety snapshot covers what the restore overwrites"
subtitle: "A restore's pre-restore snapshot is scoped from the archive's first directory member, so a bare top-level file the restore overwrites has no rollback copy."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): _archive_scope returns undef (full content snapshot) for a bare top-level member and skips the prefix's own directory entry while deepening, so a bare file at any level scopes to its parent; t/unit/manager/105 restores a mixed archive and asserts the safety tarball carries ./index.md with the pre-restore content, and pins the root / sites/edge / sites scope shapes. FOUND 2026-08-25 by the backups structural review, PROVEN by probe tmp/bp-probe-archive-scope.t; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. Backups::_archive_scope (307-337) skips bare top-level members and its deepening loop returns at tar's own sites/ directory entry, so an archive carrying ./index.md and ./sites/edge/page.md scopes the safety snapshot to a subtree: the probe shows the restore overwrote index.md while the safety tarball held only ./sites/ ./sites/edge/ ./sites/edge/page.md. Fix shape from the report: a bare file at any level widens the scope to its parent (the root for a top-level file), and directory entries are skipped in the deepening."
---

# The finding

`Manager/Backups.pm _archive_scope` (307-337) decides what the restore's
safety snapshot covers. It skips bare top-level members
(`Backups.pm 316`, `next unless defined $top`), so an archive carrying
`./index.md` and `./sites/edge/page.md` scopes the pre-restore snapshot to
a subtree. The probe restored such an archive: `index.md` was overwritten
(OLD over NEW) and the safety tarball's members were `./sites/
./sites/edge/ ./sites/edge/page.md` - no rollback copy of `index.md`.

A second fact from the same probe: the deepening loop (`Backups.pm
323-336`) returns at tar's own `./sites/` directory entry (`rest` is empty
at 331), so an unscoped archive scopes to `sites`, never `sites/edge` as
the comment at 321-322 claims. Only an archive made by a scoped
`action_backup_create`, whose first member is `./sites/edge/`, deepens.

# Why it matters

Correctness: the safety snapshot exists so that a restore can be rolled
back. When the scope is narrower than the archive, the rollback copy is
missing exactly the files the restore replaced.

# The proving test

`bp-probe-archive-scope.t` as a unit test: the safety tarball carries
`./index.md`.

# Fix shape

A bare file at any level widens the scope to its parent (the root, for a
top-level file), and directory entries are skipped in the deepening.
