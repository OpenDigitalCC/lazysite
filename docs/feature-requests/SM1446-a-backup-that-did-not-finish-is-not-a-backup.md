---
id: SM1446
title: "SM1446: a backup that did not finish is never listed as a backup"
subtitle: "A full backup killed mid-tar left its empty claimed name, which the Backups page listed as a full backup with no sha256. It is now listed as unfinished, refused by restore and named by the check; the trail records the start; the page says what happened."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-12
raised-by: "0.16.12 test, row Y6"
area: manager
status-note: "SHIPPED (PENDING): an empty claim, or a cut-off archive with no sha256, is listed under unfinished, refused by restore, apply and --restore-full, and named by lazysite check; TERM mid-tar keeps nothing; the trail records the start; the page shows the outcome. A full backup runs detached and lists in progress (ruling 248). t/unit/manager/975-977, t/tools/645, 646."
---

# What was found

On a large nine-domain test instance (0.16.12) the operator took a full backup from the
manager's Backups page. `backup-list` then showed `lazysite-full-20261112T065507Z.tar.gz`, kind
`full`, size 0, sha256 empty, `sha256_status: absent`. The button returned to rest with nothing
on the page, the backup appeared only after a manual reload, and no audit row was written. The
site's previous full backup (July) is 464,087 bytes with no sha256.

# The cause

`action_backup_create` claims the final name first, as an empty file opened O_EXCL
(`_claim_name`, SM268 03-F9); tar writes into a staging directory beside it (SM885); the
finished archive is renamed over the claim; then the digest is written and the request returns,
and the generic audit line is written after the action. A request killed while tar runs leaves
the empty claim, and the listing listed every `.tar.gz` in the directory. Nothing was written to
the trail because the action never returned.

The deadlines in front of the manager API:

- the front door's relay (`lazysite-processor/front-door.pm`, the pool and one-rule templates):
  `RELAY_TIMEOUT`, 120 s by default, then TERM, 0.2 s, KILL, and a 504;
- the web server's and the proxy's own read timeouts, which are the host's configuration (60 s
  by default in both nginx's `proxy_read_timeout` and Apache's `Timeout`); the shipped Hestia
  templates set neither.

A killed manager API does not take tar with it: tar is its child and is not signalled, so it can
run on and finish its archive into the staging directory, which nothing then renames.

How long a full tar takes: `tar czf` of a 385 MiB scratch tree (128 MiB incompressible, 256 MiB
of log-like text) took 10.05 s at nice 19 on the development host (8 cores, load 1.7), about
38 MiB/s. At that rate the 120 s relay deadline is reached at about 4.5 GiB of input and a 60 s
front-end default at about 2.3 GiB. A full backup carries every domain's content and `lazysite/`
(logs, data, history) except the cache and the backups themselves, so a large instance reaches
that.

# What was done

1. **Nothing unfinished is listed as a backup.** `Manager::Backups::_unfinished` is the one test:
   an empty file is a claim tar never filled; a file with a sha256 beside it was placed whole; a
   file with none is either from before the digest or one tar wrote through its own name and did
   not finish (every archive before SM885, and site packages still), and `gzip -t` tells them
   apart. `backup-list` lists such a file under `unfinished` (name, kind, size, time, remedy),
   never under `backups`, with the same per-domain filter. `backup-restore` and site-package
   apply refuse one by name before any safety snapshot; `install.pl --restore-full` refuses one
   before anything is laid; `lazysite check` names each, with its date and how to remove it, and
   any `.stage-*` directory a killed backup left.
2. **A killed backup cleans up or is recognisably unfinished.** While tar runs, TERM, INT and HUP
   stop tar, remove the claim and the staging directory, log it and re-raise. A KILL leaves the
   empty claim, which (1) reports. The manager API records the start in the trail (`started`,
   `file=<name>`) before tar runs; the outcome row now names the file too, and a full backup's
   target is `full` (it read `manual`: the page sends `scope=full`, which the target ignored).
3. **A full backup of a large site completes (ruling 248).** `backup-create&scope=full` claims the
   name, starts a worker detached from the request with `Lazysite::Util::detach` (the registry
   rebuild's double fork and setsid, now one helper the two share) and answers at once with the
   name and `in_progress: true`. The worker runs `action_backup_create` on the claimed name - the
   same staging, rename, sha256, retention and TERM/INT/HUP cleanup - and writes the start and
   outcome rows to the trail; the request writes no row of its own for it. A marker beside the
   claim, `.<name>.pid` (pid and start time), is written before the request answers and removed
   however the backup ends; `backup-list` lists the claim under `in_progress` while that process
   is alive and the marker is under six hours old, and as unfinished otherwise. Every backup the
   engine takes writes the marker, so a content backup being taken is in progress too. Restore
   and backup-delete refuse one in progress (409), and a full backup is refused while another is
   in progress (kind `in-progress`, naming the running one and when it started, nothing claimed;
   a stale or dead marker does not block). `lazysite check` does not name the staging
   directory of a live process. The page follows a started backup in the list every 5 s, for at
   most three hours, and says done (name and size), unfinished, or failed (gone from the list).
   MCP `site_backup` makes a site package (`package_create`), not a full backup, and does not
   reach this code; it is unchanged. A site package being made writes no marker.
4. **The page says what happened.** The outcome stays beside the button: the name, the refusal,
   or, for an answer that is not JSON (the error page of a server that stopped waiting), that the
   server stopped waiting and the list will show the backup when it has finished or as
   unfinished. The list is read again whatever happened, and unfinished backups are shown apart
   with a Delete.
5. **sha256.** A finished backup records one (`write_sha256` after the rename, since SM183,
   9 Aug 2026). The 12 Nov one has none because it never finished. The July one predates SM183,
   so nothing wrote one; it also predates SM885, when tar wrote through the claimed name, so a
   killed request then left an archive that stops part way under the final name. The listing now
   tests it with `gzip -t` and lists it as unfinished if it is.

# Tests

- `t/unit/manager/975`: through `lazysite-manager-api.pl` with a tar that starts its archive and
  hangs, the request is signalled mid-tar. KILL: the claim is listed under `unfinished` with its
  time and remedy, not as a backup; the trail has the start by file name and no outcome; restore
  refuses it with no safety snapshot. TERM: nothing is left and tar is stopped. A cut-off archive
  with no sha256 is unfinished, a whole one is a backup. A finished full backup has a verified
  sha256 and start and outcome rows naming the file and `full`. An unfinished site package is
  not applied. 16 of 34 fail on 3d869ef6e. Its kill arms now use a content backup (still in the
  request); while tar runs the backup is in progress and restore refuses it as such, which fails
  4 of 38 on de7843a65.
- `t/unit/manager/976`: the page's own JavaScript in node: the outcome line for a finished
  backup, a refusal and a 504 page, the list read again each time, unfinished backups shown with
  a Delete for their kind. All fail on 3d869ef6e. The following of a full backup in progress (to done,
  unfinished, gone, and the cap) fails on de7843a65 (no `pollBackup`).
- `t/unit/manager/977`: a full backup whose tar waits 3 s answers in under 3 s with `in_progress`,
  is listed in progress, then finishes after its request and is listed with a verified sha256 and
  no marker, with exactly the worker's start and outcome rows; a worker killed with KILL lists as
  unfinished, not in progress; a marker over six hours old or of a dead process is unfinished.
  A full backup started while another is in progress is refused, naming it, with nothing
  claimed; a stale marker does not block.  Fails on de7843a65.
- `t/tools/645`: `lazysite check` names an empty claim (date, size, remedy), a cut-off archive
  and a staging directory, and not a finished backup. Fails on 3d869ef6e.
- `t/tools/646`: `install.pl --restore-full` refuses an empty claim and a cut-off archive, saying
  nothing was changed, with no docroot or cgi-bin made. Both fail on 3d869ef6e.
- `t/unit/manager/20`: its installer-archive fixture is now a whole gzip stream.
