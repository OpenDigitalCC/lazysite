---
id: SM755
title: "SM755: the supervisor restarted a dying service forever, uncounted, and status said on"
subtitle: "Found by the eight-dimension review of the daemon service before 0.13.1 (D1 F1.1, D5 experiments 6-10). The one property the plugin description promised - a flapping child is FAILED, not restarted - was inverted by the order of two loops, and no test ran the supervisor with the plugin enabled. Fixed with the reproduction as the test, plus the reliability findings the same review measured."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-05 on claude/sm755-supervisor-restart-path, before the 0.13.1 cut. t/unit/daemon/06 reproduces the crash loop (7 starts, 0 exits counted, status on) against the pre-fix code and holds the fixed behaviour; t/unit/daemon/07 holds the lock, the orphan adoption, the pid-is-not-proof rule and the torn-record WARN."
---

# What was measured

`tmp/review-0131/crashloop.pl`: a service that `_exit(1)`s at once,
`daemon_restart_backoff: 2`, twelve seconds:

```
status while running: verdict=on service=on
'service started' lines: 7
'service exited' lines:  0
```

Documented behaviour: exits counted, waits of 2, 4, 8 s, FAILED after the
seventh. Actual: a fork every ~2 s indefinitely, never counted, never logged,
never failed, reported `on`.

# Why

`Supervisor::run` counted a failure only when it saw a child gone *before*
reaping it. A dead child is a zombie until reaped and `kill 0` succeeds on a
zombie, so `_alive` said "running"; the reap loop then deleted the child from
`%child`; the next iteration found no child and spawned again. The failure count,
the backoff (`$next_try` was set only when `fork` itself failed) and the ceiling
were all on the branch that never ran. `t/unit/daemon/` proved the *disabled*
path thoroughly and never started the supervisor enabled (Supervisor at 45.7%
statement coverage; lines 300-321, 337-359, 377 at zero).

# What the same review measured beside it (D5)

| # | Experiment | Found |
| --- | --- | --- |
| 6 | `kill -9` the supervisor, start another | the orphaned scheduler ran on; a second scheduler started beside it; status showed one healthy service while two ran the same jobs on the same files; no lock, no log |
| 7 | disable the plugin while running | supervisor and scheduler kept running and ticking; status said `off` with a live pid in `detail` |
| 8 | write any live pid into `scheduler.pid` | status said `on` - `kill 0` proves a process exists, not that it is ours |
| 9 | TERM during a slow job | shutdown waits for the job with no deadline; a Perl `sleep` in a job body is cut short by the signal and recorded as a full success |
| 10 | corrupt `scheduler-runs.json` | every job ran at once, in silence |

And D4: an idle tick rewrote the run record (temp+rename) every tick with
nothing to say - 300 renames a minute across a 300-site host at the default
tick.

# What changed

- **The reap is the exit event.** Every exit is counted in the reap loop, with
  exit status and signal in the WARN; the backoff applies to the next start; past
  `$FAIL_CEILING` the service is FAILED once, with a state file. A service that
  ran `$STEADY_AFTER` seconds before dying starts its count again, so a rare
  crash over months cannot creep to the ceiling.
- **The gate is re-read while running** (`$GATE_EVERY`, 10 s): the plugin
  disabled in the manager stops the children and exits 0, the code the unit
  treats as "disabled, do not restart". Both switches, after start as well as
  before.
- **One supervisor per docroot**: an advisory lock in the state directory; a
  second is refused with exit 3 and a log line naming the reason. The child
  closes the lock handle so an orphan cannot hold it.
- **Adopt by stopping**: a supervisor that finds a service it can PROVE is its
  predecessor's - pid and kernel start time (`/proc/PID/stat` field 22) both
  match the state file - TERMs it (KILL after 10 s) before starting afresh, and
  says so. Without the start-time proof it leaves the pid alone: the one thing
  worse than a duplicate scheduler is a supervisor killing something else.
- **A pid is not proof**: `status()` asks pid AND recorded start time; a reused
  pid reads as `inconsistent`, not `on`.
- **`status()` says `starting`** for a pending restart (with the retry time) and
  `failed` only when the supervisor has given up (with the count); the top-level
  verdict follows, and the provisioning remedy is not offered for either.
- **Stop has a deadline** (`$STOP_DEADLINE`, 30 s): TERM, wait, KILL what is
  left, with a WARN naming the service.
- **A torn run record is logged** once; it still reads as empty (every job due),
  which is the safe direction.
- **An idle tick does not rewrite the record.**
- **`daemon_job_user` naming an account that does not exist is refused as
  "does not exist"** rather than "does not hold run_jobs" (D1 F1.3): the remedy
  for a typo is not a grant. `account_names()` is the reader.

# What was NOT changed, and is recorded

Experiment 9's first half: a job body written in Perl that `sleep`s is cut
short when TERM arrives, because the signal interrupts `sleep` and the body
returns normally. The real jobs do not sleep (the stats rollup waits on a
subprocess, which runs to completion), so this is a property of the test's stub
rather than of a shipped job; the contract in `Jobs.pm` should say that a body
must not treat an early return from `sleep` as completion, when a job that
sleeps exists.

# Related

SM666 (the runtime), SM222 (the vocabulary `starting`/`failed` come from),
`docs/review/0.13.1-daemon/` (the review that found it).
