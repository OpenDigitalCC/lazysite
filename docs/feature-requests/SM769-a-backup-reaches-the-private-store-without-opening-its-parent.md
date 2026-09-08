---
id: SM769
title: "SM769: a backup reaches the private store without opening its parent"
subtitle: "0.13.6 on edge (136E-08): the Backups page's own button failed every time - 'tar exited 2: <outside>/web/<domain>: Cannot open: Permission denied'. The store is the docroot's sibling, its parent is the domain folder (root-owned 0551 on Hestia), and GNU tar opens a -C directory O_RDONLY. Every backup on the host had been written by the installer; none by an operator."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm769-a-backup-reaches-the-private-store-without-opening-its-parent. The snapshot names the store as ../<leaf> from inside the docroot (tar walks through the parent instead of opening it and strips the ../, so the member name is unchanged: leaf/...); the restore extracts into the store itself with --strip-components=1 after making it with the docroot's identity; the -C parent form is kept for a symlinked docroot, decided by inode. A failed snapshot names the unix user beside tar's status and the scrubbed detail. t/unit/manager/160 reproduces the layout (parent 0311) and fails on the old file in both directions."
---

# What the field saw

136E-08, sysop cookie session, the "Create content backup" button, five
times:

```
Backup failed: tar exited 2
tar: <outside>/web/<domain>: Cannot open: Permission denied
```

Nineteen backups on the host, every one of them a deploy's: the installer's
pre-upgrade snapshots, site packages, a pre-restore. The list was never
empty, so nobody had reason to press the button, so nobody knew it did not
work.

# What was true

`action_backup_create` reached the private content store (SM286) with
`-C <parent> <leaf>`, where the parent is the domain folder. On the Hestia
layout that folder is root-owned `0551` - the request path may traverse it
and may not read it - and `Private.pm` has said so since SM323. GNU tar
implements `-C` by opening the directory `O_RDONLY` (glibc defines no
`O_SEARCH`, so gnulib's is `O_RDONLY`), which needs the read bit the request
path does not have. Reproduced locally with a parent at `0311`: the same two
lines, exit 2. The restore's private pass (`-C <parent> <leaf>`) fails the
same way, so a restore of any archive carrying gated content was equally
impossible there.

# What is built

- The snapshot names the store as `../<leaf>` from inside the docroot. tar
  walks **through** the parent (execute is enough) rather than opening it,
  strips the leading `../`, and stores the member as `<leaf>/...` - the same
  bytes the old form produced, so no archive and no restore changes shape.
  The `-C parent` form is kept for a symlinked docroot, whose `..` is the
  target's parent; the choice is made by inode.
- The restore's private pass extracts into the store itself with
  `--strip-components=1`, after making the store with the docroot's identity
  (`Private::_mkpath`) if it is absent. `--anchored <leaf>` still confines
  the pass to that one member.
- A failed snapshot carries `unix_user` beside `reason` and the scrubbed
  `detail` - the same three facts the store readers log (SM766).
- `t/unit/manager/160`: a docroot under a parent at `0311`; the backup is
  created, the archive's members are spelled exactly as on a readable
  parent, the restore puts the store back, and a failure names the user
  without the host path. Both halves fail on the old file.

# What is not built

The field asked for a standing precondition on the Backups page - "the
request path can read what it must archive", in the shape of the daemon's
`runtime_user` row - and for the two redactions (`<outside>/...` here, a
full path in the connector store's write errors) to be settled one way.
The second is settled by SM768: no path outside the site is ever printed.
The first is a candidate: with this fix the precondition on the Hestia
layout is met, and a check would now be reporting a fault the button no
longer has.
