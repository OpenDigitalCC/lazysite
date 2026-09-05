---
id: SM753
title: "SM753: backup_retention is read by three parsers with two defaults, and rotation runs only after a backup"
subtitle: "Found while choosing the scheduler's first real jobs (SM666, 0.13.1). The manager keeps 10 by default, the installer and the theme store keep 3, the same key names all of them - and the manager's rotation leaves the .sha256 sidecar behind. Not made a scheduled job until it has one reading."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL 2026-09-05 (0.13.1, commit ce7e2754): the sidecar half is built - the manager's backup rotation and backup-delete retire the .sha256 with the archive it describes (t/unit/manager/156). The one-reader half - one parser of backup_retention with one default, which today is 10 in the manager and 3 in the installer and the theme store - waits on the release manager's call on which default wins, and a scheduled rotation stays deliberately unbuilt until then."
---

# What was found

The survey of opportunistic maintenance for SM666's real jobs asked where backup
rotation happens today. Three places, three parsers of the same `lazysite.conf`
key:

| Reader | Default | Accepts | Sidecar |
| --- | --- | --- | --- |
| `lib/Lazysite/Manager/Backups.pm` `_retention_limit` | **10** | `\d+`; `0` = unlimited | `.sha256` **left behind** |
| `install.pl` `read_retention` / `apply_retention` | **3** | `\d+`; dies on anything else | retired with the artefact (SM183) |
| `lib/Lazysite/Manager/Themes.pm` `_backup_retention` (shared with Layouts) | **3** | `-?\d+` | n/a (artefact backups) |

The docs say 3 (`docs/development.md`, the theme-publishing page). A sysop who
has never set the key and takes manual backups from the manager keeps ten, reads
that they keep three, and finds `.sha256` files describing archives that no
longer exist.

**Rotation runs only after a successful backup** (`action_backup_create`, and
`SitePackage` for site packages), by design - expiring an old one before the new
one exists could lose both. Nothing else ever rotates. That is defensible: a
directory nobody adds to does not grow. It is recorded here because SM666's
scheduler is exactly where a "rotate anyway" would go, and it was **deliberately
not put there**: a timer deleting a sysop's backups is a new behaviour, and one
to build on a single reading of the key, not three.

# What to do

1. One reader. `Lazysite::Manager::Backups::_retention_limit` becomes the
   function the installer and the theme store call (the installer already loads
   engine modules for other reads), with one default and one grammar. Which
   default is the operator's call; the manager's 10 is the one live sites have
   been running under.
2. The manager's `_apply_retention` retires the `.sha256` sidecar as
   `install.pl` does. A one-line fix with a test that lists the directory after.
3. Only then consider a scheduled rotation, as an SM666 job needing `purge` -
   the grant `backup-delete` already charges - and only if a case for it exists
   beyond symmetry.

# Related

SM666 (the scheduler, and why this is not one of its jobs), SM183 (the sidecar
rule the installer follows), SM268 03-F11 (deliberate backup removal).
