---
id: SM883
title: "SM883: six unrelated operations slowed by nearly the same factor, and nothing failed"
subtitle: "Between the 2026-09-10 baseline and 0.14.1, every timed operation in the perf gate moved 1.20-1.27x - render, password verification, token verification and the stats export alike. It is reproducible on an idle host, so it is not load. Durations are reported and never failed on, so it shipped inside 0.14.0 unexamined, and the 0.14.1 re-baseline has now made it the new normal. This filing exists so that re-baselining moved a number rather than closing a question."
brand: plain
standard-margins: true
status: partial
status-note: "MEASURED 2026-10-08 (n277): THE MACHINE, not the code. Same host, interleaved, medians of 7: v0.14.1 is 1.01-1.03x the baseline's own commit (A/A noise 1-2%), while the same v0.14.1 tree now runs 1.12-1.22x faster than its 2026-09-14 figures. No bisect: the window holds no step. No code change. Residual since v0.15.2 below; 416bdffb adds 0.05 ms per verify, deliberately."
---

# What was measured

`tools/bench.pl --check` against the baseline captured 2026-09-10 on `ai-dev`
(perl v5.40.1), run on the same host:

| operation | baseline | 0.14.1 | ratio |
| --- | --- | --- | --- |
| `render_cache_hit_ms` | 65.9 | 82.5 | 1.25x |
| `render_miss_ms` | 89.8 | 114.3 | 1.27x |
| `stats_export_ms` | 588.8 | 707.5 | 1.20x |
| `verify_password_ms` | 85.8 | 104.0 | 1.21x |
| `verify_token_cli_ms` | 60.6 | 73.0 | 1.21x |
| `verify_token_ms` | 0.5 | 0.6 | 1.26x |

**Every timed operation, and all within seven percentage points of each other.**

# Why it is worth a filing rather than a shrug

**It is not host load.** The first reading was taken on a host that had been
running full suites all day, which is the obvious explanation and the wrong one:
a second run at load 0.63, and the baseline capture itself at load 0.32, gave
materially the same numbers.

**It is not one slow function.** Rendering a cached page, rendering a miss,
verifying a password, verifying a token and exporting stats do not share an
implementation. A uniform factor across unrelated paths points at something
every path pays - a module loaded at startup, a store read on each call, an
interpreter or library change - or at the machine itself having changed.

**Nothing failed, by design.** `bench.pl` reports durations with their ratio and
never fails on them, deliberately: a millisecond figure is about the machine.
Only the `work_*` counters are a ratchet. So this drift accumulated, shipped in
0.14.0 and would have shipped in 0.14.1 with no gate ever raising its voice.

# What the re-baseline did, and did not, settle

The 0.14.1 cut re-captured the baseline (`--baseline --accept-regression`,
2026-09-14) because the work counter was blocking and the tool will not
re-capture over a timing regression silently - which is SM327 working exactly as
written.

That decision was taken with the drift visible and named. **It makes the slower
numbers the new definition of correct, which is precisely what SM327 warns
about** - so it is recorded here rather than left to be rediscovered against a
baseline that no longer remembers. The next drift will be measured from 82.5ms,
not 65.9ms.

# Where to start

- **Bisect 2026-09-10 to 2026-09-13.** That window is 0.14.0's own, and it is
  short. The baseline sat exactly on `work_users_tool_statements: 3267` at
  v0.14.0, so the release is well bounded on both sides.
- **Check the machine before the code.** Twenty-nine days of uptime, a disk at
  90%, and a host that has been building releases all week. A uniform factor is
  as consistent with the environment as with the engine, and that is cheaper to
  rule out.
- **`verify_token_ms` is sub-millisecond** (0.5 -> 0.6) and should carry the
  least weight of the six: at that scale the ratio is noise-dominated. The
  informative ones are `render_miss_ms` and `stats_export_ms`, which are large
  enough for 1.2x to be real work.

# Measured 2026-10-08

**Result: the 1.20-1.27x was the machine on 2026-09-14, not the code.**
0.14.0's window contains no step, so there was nothing to bisect.

## The machine

`ai-dev`, perl v5.40.1. These are the same host and interpreter the
2026-09-10 baseline names. The host is a KVM guest with 8 vCPUs, reported as
an AMD Ryzen 7 5825U at 1996 MHz. No cpufreq is exposed, so neither the
governor nor any frequency or contention on the physical host can be seen from
inside the guest. Kernel 6.12.111+deb13-amd64, up 5 days (it was 29 days at
the filing, so the guest has rebooted since). Load average 1.2-2.8 during the
runs, from other agents' sessions, which is why every run below is
interleaved. /srv was at 81%.

## Method

A detached worktree per tree, and `tools/bench.pl` (run mode) from each tree
on its own code. The trees run interleaved, A B C ... A B C, so host drift
during the hour lands on every tree alike. The script
(`tmp/sm883-ab.pl`, scratch, kept in the gitignored `tmp/` rather than
committed) reports every reading and the median per op.

## Noise floor (A/A)

The baseline's commit `3024b757` ran as two separate labels in the same
interleave, 7 rounds each. The medians agreed within **0.1-2.1%**:

| op | A | A' | A'/A |
| --- | --- | --- | --- |
| `render_cache_hit_ms` | 68.2 | 67.7 | 0.99 |
| `render_miss_ms` | 92.3 | 92.2 | 1.00 |
| `stats_export_ms` | 615.5 | 628.6 | 1.02 |
| `verify_password_ms` | 91.1 | 92.4 | 1.01 |
| `verify_token_cli_ms` | 63.0 | 62.1 | 0.99 |

A single run can vary by up to 12% (max/min within one tree), so a single
`--check` reading cannot tell 1.1x from noise. A median of 7 interleaved runs
can. The instrument does show a real difference when one exists: n276 read
7-14% slower than `3024b757` on render and the CLI verification in every one
of the 7 rounds (see the residual section below).

## The machine check: the baseline commit and the window, side by side

Medians of 7 interleaved rounds:

| op | recorded 09-10 | `3024b757` now | v0.14.0 now | v0.14.1 now | v0.14.1 recorded 09-14 |
| --- | --- | --- | --- | --- | --- |
| `render_cache_hit_ms` | 65.9 | 68.2 | 69.4 | 69.4 | 82.5 |
| `render_miss_ms` | 89.8 | 92.3 | 93.5 | 94.0 | 114.3 |
| `stats_export_ms` | 588.8 | 615.5 | 632.6 | 633.7 | 707.5 |
| `verify_password_ms` | 85.8 | 91.1 | 90.4 | 92.5 | 104.0 |
| `verify_token_cli_ms` | 60.6 | 63.0 | 65.8 | 65.0 | 73.0 |
| `verify_token_ms` | 0.5 | 0.6 | 0.6 | 0.6 | 0.6 |

- **The code in the window is flat.** v0.14.1 measures 1.015-1.032x the
  baseline's own commit, and v0.14.0 measures 0.99-1.04x. Against a noise
  floor of 1-2%, that is at most a 2-3% accretion, not 1.20-1.27x.
- **The baseline's commit roughly reproduces its record.** It measures
  1.03-1.06x its 2026-09-10 figures today, in the 7-round run. An earlier
  5-round run, an hour before at a higher load, read 1.09-1.13x. The
  difference is the host's state during the session.
- **The same tree was the slow one on 2026-09-14.** v0.14.1 now runs
  1.12-1.22x faster than the figures recorded for it at its own cut. The code
  did not change between those two readings; the machine did.
- **`verify_password_ms` corroborates this.** It is in-process and
  CPU-bound, and its code did not change in the window (the only Auth
  changes between `3024b757` and v0.14.1 are the Paths refactor and the
  SM879 closure split, neither of them on the password path). Even so, it read
  1.21x on 2026-09-14 alongside everything else.

So the filing's two candidates for "something every path pays" resolve to
the second: the machine itself had changed. It is a guest whose CPU budget
the host decides, and after 29 days of uptime it had been building releases
all week. Its reboot since has removed the difference. What the host-side
cause was cannot be named from inside the guest.

## Bisect

**Not run.** A bisect needs a step between its endpoints, and v0.14.0 and
v0.14.1 both sit at 0.99-1.04x the baseline commit, against a step
being sought of 1.20-1.27x.

## Residual, found on the way (outside the window)

A tag sweep (5 interleaved rounds per tree, v0.14.1 to n276) was flat through
v0.15.0. Small steps follow:

| op | v0.14.1 | v0.15.0 | v0.15.1 | v0.15.2 | n276 |
| --- | --- | --- | --- | --- | --- |
| `render_cache_hit_ms` | 70.0 | 69.8 | 71.9 | 73.4 | 74.1 |
| `render_miss_ms` | 92.8 | 93.8 | 95.5 | 97.4 | 97.9 |
| `verify_token_cli_ms` | 65.6 | 65.7 | 65.6 | 68.1 | 71.5 |
| `verify_token_ms` | 0.6 | 0.6 | 0.6 | 0.6 | 0.8 |
| `stats_export_ms` | 638.5 | 626.0 | 588.8 | 599.2 | 582.5 |

- **Render and the CLI: accretion of 2-5% per release.** The processor and the
  users tool grew in each release, and nothing points at a single commit. All
  of it is well under the 1.25 tolerance, so it was not bisected.
  `stats_export_ms` moved the other way (0.91x).
- **In-process `verify_token_ms`: one step, attributed.** The bench prints
  this at one decimal from 20 calls, which is too coarse to bisect. A
  2000-call in-process micro-bench (`tmp/sm883-verify-micro.pl`, a fresh perl
  per tree per round, 7 interleaved rounds) placed it exactly. Rounds 2-7 are
  used; round 1 read about 2x on every tree alike, which was the host.

  | tree | ms per call, median |
  | --- | --- |
  | v0.15.2 | 0.268 |
  | `af719d1c` (parent of `416bdffb`) | 0.273 |
  | `416bdffb` SM906 T3, auth stores | 0.320 |
  | `2ed58cff` (parent of `77e36311`) | 0.319 |
  | `77e36311` SM906 T3, users store | 0.330 |
  | n276 | 0.330 |

  Every `416bdffb` reading (0.304-0.346) is above every reading of its parent
  (0.265-0.295). The cost is about **0.05 ms per verification**, and the cause
  is deliberate: `auth_cannot_tell()` re-opens all four auth stores after
  `effective_settings` has read them, on purpose ("the open decides",
  SM770), so that an unreadable store refuses rather than verifying as an
  empty grant. `77e36311` (a second read of the users file before
  `read_users`) adds no measurable cost. **No fix is proposed.** A remedy would
  trust the flags the earlier reads left, and that is exactly what SM770 rules
  out. At 0.05 ms against a request costing tens of milliseconds, the cost is
  not worth reopening that ruling.

## What this leaves

- **No code change.** The 0.14.0 window is clean.
- **The committed baseline (2026-09-30) carries the same host inflation.**
  n276 measures 74.1 against its 88.8 for `render_cache_hit_ms`. A
  re-capture made now would record lower numbers. It was not re-captured
  here, because re-baselining is a cut-time decision (SM327).
- **A timing budget cannot be what guards this.** A single `--check` run
  varies by up to 12% on this guest, and the guest's own speed moved 1.2x
  between two weeks. Interleaving against the baseline's own commit
  (`tmp/sm883-ab.pl`) is the measurement that separates the code from the
  host. A future drift question should start there, not from a single
  reading against the stored figure.

# Related

[[SM327]] (why a re-capture over a regression has to be stated), [[SM342]] (a
duration is about the machine, a count is about the code).
