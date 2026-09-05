# Dimension 5 - Reliability and resilience - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, clean worktree
- Date: 2026-09-05
- Regime: Commercial
- Prior verdict: none - first review of this service
- Not waivable here: this is the dimension a long-running process lives or
  dies by, and the one that has never been exercised on a real host

## Verdict

**REFUSE** at the audited commit; **cleared on `claude/sm755-supervisor-restart-path`**,
pending land. Six scripted experiments; five found the service doing the wrong
thing, one (clean stop) found it right. Every one of the five is fixed on the
branch with a test that reproduces it. The verdict stands as REFUSE for the
commit reviewed because that is what was measured, and it is what would have
shipped.

## Method

Scripted experiments under `tmp/review-0131/d5-*.pl`, each starting the real
supervisor (forked, plugin enabled) and doing to it what a host would: a clean
TERM, a `kill -9`, a plugin disabled underneath it, a stale pid file, a slow
job, a corrupted record. Reported as found; then the fix branch re-ran the same
shapes as `t/unit/daemon/06` and `07`.

## Findings

```datatable
columns: # | Experiment | At 53df9a44 | On the fix branch
widths: 0.7cm | 3.6cm | X | X
bold: 1
tone: medium
text: 5
---
5 | TERM the supervisor | PASS: exit 0 in 2 ms, child gone, pid file removed | unchanged; state file removed too
6 | kill -9, start a second supervisor | orphan ran on; second scheduler started beside it; status showed one healthy service while two ran the same jobs; no lock, no log | second supervisor refused (exit 3, logged); an orphan proved by pid + start time is stopped before a fresh start
7 | disable the plugin while running | both processes kept running and ticking; status said off with a live pid | gate re-read every 10 s; children stopped; exit 0
8 | any live pid in scheduler.pid | status said on - kill 0 is not proof of identity | pid must match the recorded kernel start time; otherwise inconsistent
9 | TERM during a slow job | no deadline: shutdown waits for the job; a Perl sleep in a body is cut short and recorded as success | 30 s deadline then KILL, with a WARN naming the service; the sleep property recorded in SM755 as a body-contract note
10 | corrupt the run record | every job ran at once, silently | still runs everything (the safe direction), and says so once
1 | (D1) a service that dies at once | restarted every 2 s for ever, uncounted, status on | counted, backed off, FAILED at the ceiling, status failed with the count
```

### F5.1 - The clean path was right (PASS)

Experiment 5: SIGTERM to the supervisor, child in its sleep: exit 0 in 0.002 s,
scheduler dead, pid file removed, log ends `service stopped` / `supervisor
stopped`. One note: `status()` after a deliberate clean stop reads
`inconsistent` / "has not been started", identical to never-started. True in
the contract's terms (desired on, not running) and the remedy (`systemctl
enable --now`) is the right one for both; a `stopped_at` in the state file
would let the message distinguish them. Low.

### F5.2 - Two schedulers on one docroot (REFUSE, fixed)

Experiment 6 is the one that would have corrupted data: two schedulers writing
the same run record, running the same rollup and sweep against the same files,
with `status()` seeing only the newer. `run()` never read the pid file before
spawning and took no lock. Fixed: an advisory lock held for the supervisor's
life (the child closes its copy), and adoption-by-stopping for an orphan whose
pid *and* kernel start time match the previous supervisor's record - without
that proof the pid is left alone, because killing something else is worse than
a duplicate.

### F5.3 - Disabled did not mean off, after start (REFUSE, fixed)

Experiment 7 is D1 F1.2 measured: the gate was read once. `status()` even said
`off`, `healthy`, with the live pid in `detail` - a status that contradicts
itself in one document. Fixed with a periodic gate read and a clean exit 0.

### F5.4 - A pid is not proof (WARN, fixed)

Experiment 8: `kill 0` succeeds for any live process the user can signal. The
supervisor now records `/proc/PID/stat` field 22 at spawn and `status()`
requires it to match. Where `/proc` is absent the check degrades to the pid,
which is what it was.

### F5.5 - Shutdown latency is bounded by the slowest job (WARN, bounded)

Experiment 9: the stats subprocess ran to completion (3.0 s after TERM in the
test; up to the cold-ingest 4.4 s measured in D4) with no deadline of the
daemon's own, so systemd's `TimeoutStopSec` was the only bound. Now 30 s then
KILL, logged. The other half - a body that `sleep`s returning early on TERM and
being recorded `ok` - is a property of a stub, not a shipped job, and is
recorded in SM755 as a sentence the body contract should carry when a sleeping
job exists.

### F5.6 - A torn record is loud now (WARN, fixed)

Experiment 10: the safe direction (everything due) was already taken; it was
taken silently. One WARN per occurrence.

### F5.7 - Packaging: nothing reloads systemd on upgrade (WARN, carried to D8)

The 0.13.0 `lazysite-common` deb ships both unit files and no `postinst`; a
changed unit is not seen by running instances until an operator runs
`daemon-reload`. Pre-existing for the pool unit; recorded under D8 F8.4 as
build-side with the cause unestablished.

### F5.8 - Still never run on a real host (WARN, carried)

Every experiment here ran unprivileged, under the reviewer's uid, without the
unit. The privilege drop, the sandbox directives, `Restart=on-failure` with the
start limit, and `--daemon` provisioning are proved by reading and by the pool's
precedent. The first provisioned instance is the test this dimension is waiting
for; until then the honest statement is that the service is reliable *in the
shapes a test can make*.

## Recommendations, by impact

1. Land the SM755 branch before the cut; it clears F5.2-F5.6 with tests that
   reproduce each.
2. Provision one real instance (`lazysite-hestia-domain add ... --daemon`) on
   edge and run the D5 shapes by hand once: TERM, `kill -9` + restart, disable
   in the manager. Record in the Hestia README or `docs/RELIABILITY.md`.
3. F5.7 with D8 F8.4.
4. `stopped_at` in the state file (F5.1) when `status()` is next touched.
