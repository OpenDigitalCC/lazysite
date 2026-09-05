# Dimension 3 - Test coverage - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, clean worktree
- Date: 2026-09-05
- Regime: Commercial
- Prior verdict: none - first review of this service

## Verdict

**WARN** at the audited commit; **improved on `claude/sm755-supervisor-restart-path`**,
where `t/unit/daemon/06` and `07` run the supervisor enabled and Supervisor.pm
moves from 45.7% to **91.3%** statement (37.5% to 73.9% branch; scope total 60.5%
to 75.8%). The tests that exist are good tests - each asserts a property, several
caught real defects before they shipped, and the newest runs the real stats
plugin rather than a stub. What is missing is the supervisor's process
management: the run loop, spawn, restart, reap and stop are at zero, which is
where D1's REFUSE lives. Coverage is uneven in exactly the way that matters most
for a long-running process.

## Method

A scoped `Devel::Cover` run (`tmp/review-cover.sh`: `-select` on the service's
files, over `t/unit/daemon/`, `t/unit/lib/50`, `t/unit/manager/`, `t/tools/66`;
198 test files, 2250 tests, PASS). Per-file statement/branch/condition/sub from
the text report; the zero-hit lines mapped back to the source. Then a read of the
seven service tests against the framework's `invalid-test` catalogue.

## Findings

### F3.1 - Coverage by file (measured)

```datatable
columns: File | stmt | bran | cond | sub | total
widths: 6.2cm | 1.3cm | 1.3cm | 1.3cm | 1.3cm | 1.3cm
bold: 1
tone: medium
text: 6
---
lib/Lazysite/Daemon/Jobs.pm | 100.0 | 71.4 | 60.0 | 100.0 | 91.1
lib/Lazysite/Lifecycle.pm | 100.0 | 87.5 | 71.4 | 100.0 | 89.0
lib/Lazysite/Daemon/Service/Scheduler.pm | 78.7 | 76.0 | 40.7 | 86.6 | 73.9
lib/Lazysite/Manager/Sessions.pm | 61.5 | 40.0 | 18.7 | 78.5 | 51.2
lib/Lazysite/Daemon/Supervisor.pm | **45.7** | **37.5** | 18.1 | 66.6 | **42.1**
```

`tools/lazysited.pl` and `plugins/daemon.pl` do not appear: both are exercised
only as subprocesses (`t/unit/daemon/03`, `04`) that clear `PERL5OPT`, so the
instrumentation does not reach them. Their coverage is therefore *unmeasured*,
not zero - a distinction the next review should keep.

### F3.2 - The supervisor's process management is untested (WARN, the material one; fixed on the branch)

Zero-hit lines in `Supervisor.pm`: 300-321 (the restart/backoff/ceiling logic
inside the loop), 337-359 (`_spawn`), 377 (`_stop_children`). No test starts the
supervisor with the plugin enabled. `t/unit/daemon/01` and `03` prove the
*disabled* path thoroughly - which is the security property and was the right
first choice - but the enabled path exists only as prose in the comments, and
D1 F1.1 is what that prose was hiding.

`Scheduler.pm`'s zero lines are 296-306: `run()`'s loop and its TERM handling -
the same class (the long-running path) one level down.

### F3.3 - The tests that exist are sound (PASS)

Read against the `invalid-test` catalogue:

- No tautologies. `t/unit/daemon/01`'s strongest assertion is on the
  *filesystem* (no state directory), not on a return value.
- No mock-only assertions on the load-bearing path. `05` runs the **real**
  `plugins/stats.pl` against a hit dated yesterday and asserts the durable day
  file; the stub variant asserts the argv/env contract separately.
- `05` reads the manager API's gate table from source rather than restating it,
  so a moved gate fails the scheduler test - a parity check with one source.
- `04` moved to the contract vocabulary with the code, and asserts the *meaning*
  (not healthy, remedy names the command) rather than the words alone.
- Two defects were caught by these tests before commit (the list-assignment
  slip in the sweep; the leaked `/tmp/plugins` fixture that made a not-found
  assertion pass for the wrong reason, SM754). Tests that fail for real reasons
  are the evidence that they are not written to match the implementation.

### F3.4 - `t/unit/daemon/05` is the one test that would notice a host layout change (note)

Its `site()` fixture is one level down from the tempdir *because* a sibling
`plugins/` beside a bare tempdir was found on this host. Every other fixture in
scope uses a bare `tempdir()`; SM754 records the general case.

## Recommendations, by impact

1. `t/unit/daemon/06`: start `Supervisor::run` in a forked process with the real
   `services()`, then with an overridden dying service. Assert: the scheduler
   child appears and its pid file is written; on TERM both stop and the pid file
   is removed; a dying service is counted, backed off, reported `failed` by
   `status()`, and stops being restarted at the ceiling. This is the test D1's
   fix must ship with.
2. A `Scheduler::run` test with `daemon_tick_seconds: 1` and a TERM after one
   tick (D5's experiment 9 is the shape).
3. Measure `lazysited.pl` by running its disabled path in-process (or with
   `PERL5OPT` preserved for the coverage run only) so the privilege-drop refusals
   count.
4. Bring `Sessions.pm` up when `sweep_expired` is next touched: the list and
   revoke actions (lines 95-149) are covered by no unit test in the scope run,
   only by integration tests outside it.
