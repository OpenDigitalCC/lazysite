---
id: SM896
title: "SM896: Devel::Cover leaks one hidden lock file per structure file per process, and a full gate run is four million of them"
subtitle: "Why both 0.14.3 cuts died at the report step: not memory, inodes. 4,131,376 of the 4,132,409 entries under cover_db/structure were zero-byte dotfiles named .<digest>.<pid>.lock that Devel::Cover 1.44 creates on every structure write and never removes. The real structure files number 1,031. The filesystem has 4,751,360 inodes in total; the preflight believed a run needed 1.1M."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-21
raised-by: engine agent
area: release
status-note: "MEASURED, BUILT on claude/n145e, and the fix VERIFIED over the second cut's kept DB: with the 4,131,376 locks reaped, the new coverage.sh in REPORT_ONLY mode ran cover once over 7,198 runs in six minutes and every gated CGI cleared its floor (dav 95.4/77.0, processor 89.8/74.4, manager-api 82.4/68.7, auth 85.7/66.7, mcp 88.1/67.6, oauth 99.4/93.3, users 91.5/72.5, bundle-apply 90.6/73.0; exit 0), wrote NO pass record, and kept cover's stderr - sixteen benign 'ignoring extra statement/subroutine/branch' lines, the first time those words have been seen. So both dead cuts were inode exhaustion and nothing else. THE CAUSE: Devel/Cover/DB/IO/Base.pm _lock opens \"$file.lock\" for every read and write and never unlinks it; only DB::clean does, and nothing calls it before `cover -delete`. Structure files are written through a per-process temp (structure/.<digest>.<pid>) so the lock is structure/.<digest>.<pid>.lock - one per structure file per PROCESS, private to that pid, a hidden dotfile `ls` does not show, which is how four million files looked like two thousand. A one-test probe: 8 processes gave 69 locks, 16 gave 141, structure files stayed at 9. The full suite is 7,198 processes x ~574 files. THE STRATEGY: (1) coverage.sh reaps locks older than a minute every 30 s beside the suite - a lock guards a temp file nobody else can touch and a write is milliseconds, so nothing measured changes and the DB is bounded to thousands of inodes; (2) all remaining locks are removed before cover reads the DB, and the DB's footprint is printed; (3) release.sh's preflight floor is 200k against a measured ~40k, replacing 1.2M against an assumed 1.1M that was 4x too low; (4) SM895's G1/G2 - stderr kept, cover run once, release.sh naming the stage that failed. Plus LAZYSITE_COVER_REPORT_ONLY=1, which never writes the pass record. Reproduced by the reaper alone: deleting the locks took /srv from 0 free inodes to 4.13M free with nothing running. A SECOND CEILING, observed and not yet acted on: cover's merge over 7,198 runs reached at least 3.1 GB RSS with 3.0 GB left available on a 9.7 GB host. It is not the cause of either failure and the run completed, but it is the next limit the same step sits under; merging runs incrementally so cover never holds all of them is the candidate, recorded here rather than built. PARTIAL until the fix has gated a real cut; the third cut of 0.14.3 runs with an external reaper as the bridge."
---

# What happened

Both attempts to cut 0.14.3 ran the instrumented suite to a clean PASS — 932
files, 14,704 tests, about two hours — and then `cover -silent -report text`
printed nothing and coverage.sh exited before the floor comparison. [[SM895]]
recorded the mechanism in the scripts (stderr discarded, `grep`'s exit status
taken for `cover`'s, the wrong stage named, the evidence deleted) and declined
to name the trigger. This is the trigger.

| Reading | Value |
| --- | --- |
| `/srv` inodes, at the second attempt's end | 4,751,360 used of 4,751,360 — **0 free** |
| `cover_db` | 4,154,006 inodes |
| `cover_db/structure` entries | 4,132,409 |
| …of which `.lock` | **4,131,376** |
| …real structure files | 1,031 |
| `cover_db/runs` | 7,198 run directories, 21,595 inodes |
| `/srv` free inodes at the first attempt's launch | 4,164,568 |

The first attempt reached the report step with fewer free inodes than the
locks it had written. `cover` could not create its own lock and temp files,
printed nothing, and coverage.sh took `grep -v`'s exit 1 for a failure of the
suite. release.sh then removed the stage — which is the only reason the second
attempt could start, and the second attempt kept its stage, which is the only
reason this could be measured.

# The cause, in Devel::Cover 1.44

`Devel/Cover/DB/IO/Base.pm`:

```perl
sub _lock {
  my ($file, $type) = @_;
  my $lock = "$file.lock";
  open my $fh, "+>>", $lock or die "Can't open $lock: $!\n";
  flock $fh, $type or die "Can't lock $lock: $!\n";
  $fh
}
```

Taken on every `_read` (`LOCK_SH`) and every `_write` (`LOCK_EX`). Nothing
unlinks it. `DB.pm`'s `clean` sub removes `*.lock` under the DB, and it runs
on `cover -delete` — not at the end of a run, not before a report.

Structure files are content-addressed (`Structure.pm:280`,
`"$base/structure/$digest"`, an MD5 of the source), so the real files
deduplicate to one per source file. But they are written through a
per-process temp file, `structure/.<digest>.<pid>`, renamed atomically into
place — and the lock is taken on the *temp*: `structure/.<digest>.<pid>.lock`.
One per structure file per process, unique by construction, never removed, and
a dotfile.

**A one-test probe**, DB on another filesystem, PERL5OPT exactly as coverage.sh
sets it:

| Processes | Structure files | Locks |
| --- | --- | --- |
| 8 | 9 | 69 |
| 16 | 9 | 141 |

The full suite: 7,198 processes × ~574 files each.

## Why nobody saw four million files

`ls` without `-a` does not list dotfiles. A listing of `structure/` showed
about two thousand names — the 1,031 digests and their `<digest>.lock`
siblings — and my first sample was taken that way and concluded the directory
was small. `ls -f | wc -l` gave 4,132,409.

# The strategy

Four parts, and the first is the one that matters.

| Ref | Change | Where |
| --- | --- | --- |
| R1 | **Reap locks during the run.** A background loop beside `prove` deletes `structure/.*.lock` older than one minute every 30 s. A lock guards a temp file whose name carries the writer's pid — no other process ever contends for it — and a structure write takes milliseconds, so a lock older than a minute belongs to a write that has finished. Bounds the DB to live processes × files: thousands, not millions. Zero effect on what is measured. | `tools/coverage.sh` |
| R2 | **Clean before reporting, and say the footprint.** Every remaining `*.lock` is removed before `cover` reads the DB (what `DB::clean` would do, at the moment it should), and `coverage: DB footprint N inode(s), M run(s)` is printed so the number below is checkable against a log rather than a memory. | `tools/coverage.sh` |
| R3 | **A preflight number that was measured.** The floor was 1.2M against an assumed need of 1.1M — passed twice on a filesystem that could not hold the run. It is 200k against a measured ~40k (DB ~25k with locks reaped, clone ~11k), and the comment says where the number came from and how to re-check it. | `tools/release.sh` |
| R4 | **SM895's G1 and G2.** `cover`'s stderr is kept beside the suite log (which release.sh already keeps outside the stage); `cover` runs once, not twice (~12 min each on this suite); an empty report or a non-zero `cover` is `THE REPORT STEP FAILED`, exit 4, and release.sh names the stage rather than inferring it from a string's absence. | both |

Plus `LAZYSITE_COVER_REPORT_ONLY=1`: report on an existing DB without the
two-hour suite — the thing being done by hand today on the kept stage. It
never writes the pass record, because a report over a DB somebody chose is not
a gate run of this tree.

**Reproduced by the reaper alone, before any of this was written:** deleting
the locks from the kept DB, with no process alive, took `/srv` from 0 free
inodes to 4.13M free. The report step then ran.

## What the strategy does not do, and why

- **No bigger filesystem.** With R1 the run needs ~40k inodes. Sizing a stage
  volume for 4M+ would be building for the leak rather than fixing it.
- **No change to the stage-removal default (SM895 G3).** `release.sh`'s own
  history ([[SM328]]) removes a failed stage because four failed cuts in a day
  exhausted a tmpfs. With `cover`'s stderr kept outside the stage, the common
  failure is diagnosable without the DB. If a DB is wanted, `--keep-stage` and
  `REPORT_ONLY` are the pair. Pruning older stages at start so the last failed
  one can be kept by default is the reconciliation, and it is not built here.
- **No upstream fix in this tree.** The leak is Devel::Cover's. Reporting it
  upstream is worth doing and is not this project's release work; R1 stands
  whether or not it is ever fixed there.

# Related

[[SM895]] (the gate's reporting, filed before the trigger was known),
[[SM328]] (why a failed stage is removed), [[SM280]] (the sharded instrumented
run — more processes, so more locks), [[SM552]] (the exit-status capture that
let release.sh reach a verdict at all).
