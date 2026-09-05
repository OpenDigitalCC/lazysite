# Dimension 4 - Performance - the daemon service, pre-0.13.1

- Audited artefact: `main` at `53df9a44`, clean worktree
- Date: 2026-09-05
- Regime: Commercial
- Prior verdict: none - first review of this service
- Not waivable here: the process is long-running and the host may run
  hundreds of it

## Verdict

**WARN.** The work the daemon does is cheap and measured; what it costs to
*exist* is not small when multiplied by the fleet it was designed for. Two Perl
processes per instance at roughly 10 MB PSS each, and the hourly stats rollup,
are both affordable and both worth knowing before the first host with two
hundred sites turns it on. One idle-path defect (a rename per tick with nothing
to say) is fixed on the SM755 branch.

## Method

Scripts under `tmp/review-0131/` (`d4-rss.pl`, `d4-tick.pl`,
`d4-stats-rollup.pl`, `d4-idle-io.pl`), run as the unprivileged user against a
fixture docroot one level below a tempdir. RSS and PSS from `/proc/PID/status`
and `smaps_rollup`; tick timing with `Time::HiRes`; the stats export timed cold
and warm over a synthetic 30 days x 2,000 lines; the idle loops read from the
code and syscall-counted with `strace -c`.

## Findings

### F4.1 - Memory at rest: two processes per instance (WARN)

```datatable
columns: Measure | supervisor | scheduler | per instance
widths: 5cm | 2.2cm | 2.2cm | X
bold: 1
tone: medium
text: 4
---
VmRSS, started as systemd does (lazysited.pl) | 12.31 MB | 11.07 MB | 23.38 MB
PSS (shared pages apportioned) | 5.26 MB | 5.37 MB | 10.63 MB
Private_Dirty (truly private) | 1.72 MB | 2.17 MB | 3.89 MB
```

Multiplied: 100 instances ~1.06 GB PSS (floor 0.39 GB private); **300 instances
~3.1 GB PSS (floor 1.2 GB)**. The naive RSS sum (7 GB at 300) overstates it
because the perl binary and its libraries are shared clean pages, but the PSS
figure is what the host actually pays. For comparison the FastCGI pool is also
per-site and larger, so this is not a new class of cost - it is a second
per-site resident process on a host that already carries one.

Two processes because SM666 decided one process per service, for isolation; in
phase 1 there is one service, so the supervisor exists to supervise exactly one
child. The isolation argument is sound for phase 2 (a socket service beside the
scheduler) and costs a process now. Options, in order of preference: accept and
document the figure in the Hestia README beside the "cost at rest" paragraph
(which currently says "nothing", and is right about CPU and wrong about memory);
or let the supervisor run a single service in-process until a second exists.
Recommendation: the first, now; the second only if a real host shows pressure.

### F4.2 - The tick is cheap; the idle path had one waste (PASS, fixed)

`Scheduler::tick`: **28.2 ms** with all three jobs due on an empty site
(includes spawning the stats plugin); **0.7-0.9 ms** when nothing is due.
Idle wake-ups: two `sleep 1` loops per instance (600/s across 300 sites), no I/O
per wake in either loop. Per idle tick at the default 60 s: 90 syscalls, of which
`auth/groups` and `groups-settings.json` are read twice (`caps_for` in
`resolve_job_user` and again in `tick`) and - the finding - **the run record was
rewritten by temp+rename even when nothing ran** (inode changed on every tick).
300 no-op renames a minute across a 300-site host at the default tick; 300 a
second if an operator set the tick to 1. Fixed on the SM755 branch (`_write_runs
if @done`); the double `caps_for` read is left, at ~4 file reads a minute.

### F4.3 - The stats rollup: cold once, then cheap (PASS, with a budget)

Synthetic month, 60,000 lines / 5.6 MB:

- cold (first export, full ingest): **4.42 s wall / 4.38 s CPU**
- warm (cached day buckets): **0.56 s wall / 0.57 s CPU**
- `lazysite/cache/stats-export.json` afterwards: 770 KB

Hourly across 300 sites: **~170 CPU-seconds per hour, ~68 CPU-minutes per day**
- under 5% of one core, continuously, for the fleet. The cold ingest is paid
once per site at first enable (22 minutes serial for 300 sites, spread over
their first ticks). This is the work SM340 measured being paid by whichever
visitor arrived first; it is now paid by a clock, at a predictable rate, and no
longer on a request. That is the trade the scheduler was built for, and the
number says it is a good one.

### F4.4 - What was not measured

The daemon on a real host, under the unit, with the sandbox directives in
force. `ProtectSystem=full` and `PrivateTmp` should cost nothing measurable, but
"should" is the word this review is trying to retire for this service. Measure
RSS and the cold rollup on the first provisioned instance and record them in
the Hestia README's cost paragraph.

## Recommendations, by impact

1. Put the memory figure in the README where "costs nothing" is (F4.1) - one
   paragraph, before the first fleet host enables it.
2. Land the idle-rename fix (SM755 branch, F4.2).
3. Record real-host numbers on first provisioning (F4.4).
4. Read `caps_for` once per tick (F4.2) when Scheduler is next touched.
