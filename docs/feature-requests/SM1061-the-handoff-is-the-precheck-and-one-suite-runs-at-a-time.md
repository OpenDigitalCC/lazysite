---
id: SM1061
title: "SM1061: the handoff is the precheck, and one whole suite runs at a time"
subtitle: "A targeted subset on each commit and handoff, the whole suite on demand and for a release, an area subset and a nightly run as safety nets - and a host-wide lock so whole-suite runs never pile up."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: release manager, 2026-10-12
area: release
status-note: "SHIPPED (0.15.5) on n551: handoff runs the precheck only (--full/--release add the suite); tools/suite.sh is the one whole-suite runner, behind a lock in the common git dir; precheck adds each touched area's tests (tools/precheck-areas.pl, lint 255); tools/overnight.sh runs queued handoffs then suite.sh --nightly at 00:30. t/tools/106, 141-145."
---

# What happened

On 2026-10-12, on an 8-core host, four agents each ran the whole plain suite
(~2,000 CPU-seconds, ~1,200 files) in their handoff at the same time. The load
reached 26-30, and each suite slowed from ~1,080 s to ~1,950 s.

The handoff suite caught nothing that day. Every handoff fault was caught by the
precheck (lint 210; a `.json` fixture), and the one real cross-stack clash -
`t/unit/processor/101`, broken by a change to `lazysite-processor/sources.pm` -
was caught by the whole-suite run on main after a landing. That matches the
standing rule "gate per batch, not per change".

# The ruling

The release manager asked "what is most efficient" and took the coordinating
session's recommendation:

1. handoff runs precheck only;
2. the whole plain suite runs once, on main, after each landing;
3. a host-wide lock lets only one whole-suite run go at a time.

The same day the release manager revised it. In the coordinating session's
relay: *"a targeted subset on each commit and handoff (precheck); the whole
suite ON DEMAND (tools/suite.sh); the whole suite REQUIRED for a release (the
full gate and `handoff --release`); and, as safety nets, 'Area subset +
nightly'."* The nightly run time: *"After midnight"*. And handoffs too heavy for
the day: *"kill these off and run over night"*.

# What was built

The handoff
: `tools/handoff.sh` runs, by default, only what is per branch: a clean tree,
  the generators, the mangled-literal check, the precheck on each stack branch,
  and the tracked-tree check. Its READY line says `precheck passed`. `--full`
  adds the whole suite, through `tools/suite.sh`; `--release` implies `--full`
  and adds the bench. Releasing the worktree is unchanged.

The one whole-suite runner
: `tools/suite.sh` runs `prove -lr -j<nproc> t/` in the current worktree, under
  a `flock` on `lazysite-suite.lock` in the repository's COMMON git dir, so every
  worktree shares it. A second run waits, printing who holds the lock from the
  note written beside it (pid, cwd, branch, start). The log is the worktree's
  `tmp/suite.log`; what is printed is the `Files=` line or the failures.
  `make test`, `make tier-review`, `make tier-release` and
  `scripts/pre-review.sh suite` all go through it.

The area subset
: `tools/precheck.sh` now also runs the tests that cover each AREA a change
  touches, from the one map in `tools/precheck-areas.pl` (a changed file takes
  the row with the longest prefix it starts with). The rows were derived from
  which test directories name each area. `t/lint/255` checks that every
  top-level code area has a row, that every selector selects a test, and that
  nothing but `tools/suite.sh` runs the whole suite.

The nightly run
: `tools/suite.sh --nightly` runs the suite on main's tip in a detached worktree
  it manages (`tmp/wt-nightly`), under `nice -n 19` and `ionice -c3`, through
  the same lock - but a nightly run that finds the lock held logs a line and
  exits rather than queueing. It stops after 5 hours. The log is
  `tmp/nightly/DATE.log` (the newest 14 kept); a failure files
  `inbox/DATE-nightly-suite-failed-on-SHA.md` with the failing files and their
  first failure lines, and a pass files nothing.

The overnight queue
: `tools/overnight.sh --queue WORKTREE TIP [--full|--release]` queues a
  handoff; `tools/overnight.sh`, run at 00:30 from claude's crontab, takes the
  queue, runs each handoff in turn at nice 19, writes the verdicts to
  `tmp/overnight/results-DATE.txt`, and then runs the nightly suite. It replaces
  the interim `tmp/overnight/run-handoffs.sh`.

# Size of the area subset

Measured from the 2026-10-07 `prove --timer` run (1,017 files, 361 s wall at
`-j4`, 1,432 s of per-file wall time summed), as the summed per-file time a
selection costs before `-j`:

| A change to | Test files | Summed per-file time |
| --- | --- | --- |
| one manager module (`lib/Lazysite/Manager/Files.pm`) | 321 | ~200 s |
| one processor part (`lazysite-processor/sources.pm`) | 174 | ~100 s |
| an auth module (`lib/Lazysite/Auth/Session.pm`) | 99 | ~200 s |
| a data module (`lib/Lazysite/Data/Query.pm`) | 55 | ~16 s |
| the whole suite | 1,198 | ~1,430 s |

Divided by the same ~4x parallelism the whole suite saw, that is under a minute
for the largest area on a quiet host, and a few minutes on a loaded one - minutes,
not the suite. The manager row is the largest; if it proves slow in practice, the
narrower rule is to run `t/unit/manager/` tests that name the changed module's
package or its manager action file, plus the API-driving integration tests.

# What was left alone

`tools/gate-main.sh` runs no suite itself: it runs `tools/release.sh gate`, which
runs `prove -lr -j4 t/` in a fresh staged clone (whose git common dir is its own,
so `tools/suite.sh`'s lock would not be shared from there), tees the output for
the receipt, and is pinned by t/lint/208 and t/tools/75. Routing it through
`tools/suite.sh` would change the gate's parallelism, its log and its receipt, so
it was not done here. Two options are open for a ruling:

- `tools/gate-main.sh` holds the suite lock around its `release.sh gate` call -
  a change to gate-main.sh alone, but the gate then holds the lock through bench
  and coverage too (the coverage run is a second, instrumented whole suite), up
  to ~75 minutes;
- `tools/release.sh` takes the origin repository's lock around its staged
  `prove` only - narrower, but it changes release.sh and the line t/lint/208
  pins.

Ruled 2026-10-12, neither: "i think neither - becuase a release cant run when
there isnt  suite run, so it simply manages itself without any furthec
omplexity, if i understood that correctly". The gate stays outside the lock.
The one care left is timing: a gate is not started where it would still be
running at 00:30, when the overnight run starts.

# Since

The same day the release manager ruled that the queue is tested together, as
it will land: "maybe the suite runs on its own branch, not main, then the
review process checks that in to main". SM1062 builds it; the overnight queue
described above now feeds `tools/integration.pl`.
