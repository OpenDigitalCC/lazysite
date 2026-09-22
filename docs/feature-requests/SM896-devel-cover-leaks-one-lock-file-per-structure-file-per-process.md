---
id: SM896
title: "SM896: Devel::Cover leaks one hidden lock file per structure file per process, and a full gate run is four million of them"
subtitle: "Why both 0.14.3 cuts died at the report step: not memory, inodes. 4,131,376 of the 4,132,409 entries under cover_db/structure were zero-byte dotfiles named .<digest>.<pid>.lock that Devel::Cover 1.44 creates on every structure write and never removes. The real structure files number 1,031. The filesystem has 4,751,360 inodes in total; the preflight believed a run needed 1.1M."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-21
raised-by: engine agent
area: release
status-note: "SHIPPED - the fix gated a real cut. 0.14.4 (2026-09-22) was the first cut through the fixed gate, with NO external reaper: one attempt, tagged 18:37, and the gate printed the line this filing built - 'coverage: DB footprint 15671 inode(s), 7309 run(s)'. Mid-run, measured directly: 133,149 live locks at 6,025 processes, /srv at 12% inodes, 5.5 GB available - the population younger than the reaper's one-minute threshold (~100 processes a minute x ~574 files), so the run's PEAK is ~170k inodes with the clone, and the estimate of 'a few thousand live locks' in R1 was wrong by two orders while the mechanism was right. release.sh's preflight floor moves from 200k to 500k with that measurement as its source, and its message says the footprint line is the post-clean figure, not the peak. THE CAUSE, for the record: Devel/Cover/DB/IO/Base.pm _lock opens \"$file.lock\" for every read and write and never unlinks it; the lock is structure/.<digest>.<pid>.lock - one per structure file per process, private to that pid, a hidden dotfile - 4,131,376 of them on the 0.14.3 cut on a filesystem with 4,751,360 inodes. Both 0.14.3 attempts died at the report step with the filesystem full. The strategy that shipped: (1) a reaper beside the suite deleting locks older than a minute every 30 s; (2) every remaining lock removed before cover reads the DB, and the footprint printed; (3) the preflight floor measured, not remembered; (4) SM895's G1/G2 - cover's stderr kept, cover run once, release.sh naming the stage that failed; plus LAZYSITE_COVER_REPORT_ONLY=1, which never writes the pass record. STILL RECORDED, FOR LATER: cover's merge reached 3.1 GB RSS over 7,198 runs on a 9.7 GB host - the next ceiling the same step sits under; incremental merging is the candidate. And an upstream report to Devel::Cover, worth making, not this project's release work."
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
