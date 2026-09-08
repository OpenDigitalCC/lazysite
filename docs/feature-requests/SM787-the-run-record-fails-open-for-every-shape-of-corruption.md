---
id: SM787
title: "SM787: the run record fails open for every shape of corruption, not just the one"
subtitle: "Security review, 0.13.8, VERIFIED: _read_runs guards the top level only, so a record that is valid JSON with a non-hash job value passes the guard and then dies in tick - every interval, forever, because the file is only rewritten when a job completes. The module's own comment promises the opposite: 'reads as empty - every job due at once - which is the safe direction'. That promise holds for a total parse failure and fails for a partial one."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/secrev-residue-daemon-and-dav. _read_runs drops any entry that is not a job record, with a WARN naming them, so structural corruption collapses into the behaviour the module already documented - that job is due now, logged once - instead of a tick that dies identically forever. tick reads defensively beside it, and treats a non-numeric or FUTURE last_run as never run: the record is same-uid-writable, so a future stamp silently suppressed one job, and an occasional harmless re-run is a better failure than a job that never runs and says nothing."
---

# The finding

`_read_runs` (`Scheduler.pm:204-218`) returns `$d if ref $d eq 'HASH'` - a
top-level check and nothing more. `tick` then reads
`$runs->{$name}{last_run}` (`Scheduler.pm:284`). A record of
`{"stats-rollup":"boom"}` is valid JSON, is a top-level hash, and kills the
tick under strict refs. Reproduced here:

    Can't use string ("boom") as a HASH ref while "strict refs" in use

`run()` wraps `tick` in an eval, logs, sleeps and retries, and `_write_runs`
runs only `if @done` (`:348`) - so nothing repairs the file and **no job ever
runs again** until a human edits it. The remote surfaces cannot read the system
tree by design, so no operator screen can show them why.

**This is a declaration the code ignores** (the standing rule): the comment at
`Scheduler.pm:189-193` states the safety property, and the code holds it for
one shape of corruption out of two. Same-uid boundary, no privilege gain -
but a permanent stop of all maintenance from one malformed file.

# What is asked

Collapse structural corruption into the behaviour that is already designed and
documented - drop any non-hash job entry in `_read_runs` before returning, so a
bad entry means "that job is due now", logged once, exactly as a total parse
failure already does. A defensive read in `tick` costs nothing beside it.

A test that writes `{"stats-rollup":"boom"}` and asserts the other jobs still
run pins it, and is the test that would have caught this.

# The second half: the record is same-uid forgeable

Filed with it because it is the same file. A future `last_run` suppresses one
job silently and permanently (`$now - $last < $every` stays negative), and
`Supervisor::status` returns `run_record` verbatim to the operator
(`Supervisor.pm:461`, `daemon.pl:204`), so a forged `outcome`/`actor` lands on
the one window an operator has. The genuine trail (`log_event`) is unaffected.

The cheap half is treating a non-numeric or future `last_run` as 0 - an
occasional harmless re-run beats a job that never runs and says nothing. The
rest is a documentation decision: `{runs}` is a same-uid cache, not audit, and
should say so where it is surfaced.

# Provenance

`inbox/2026-09-08-daemon-scheduler-run-record-crash-loop-and-forgery.md`.
Accepted after reproducing the crash independently.
