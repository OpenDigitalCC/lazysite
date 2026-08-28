---
title: "SM663: the authenticated request got fourteen per cent slower, one or two milliseconds at a time"
subtitle: "Engine agent, 2026-08-28: measured while checking whether 0.11.3's bench warning was machine load. It was not."
brand: plain
standard-margins: true
status: candidate
---

# What was measured

`verify-credential` runs on every authenticated request. Timed at 40 calls per
point on an idle host, the same docroot shape, same Perl:

| Point | ms/call |
|---|---|
| v0.11.2 | 50 |
| SM598/SM606/SM608 `396af643` | 53 |
| SM641 `f71d0917` | 50 |
| SM658 `b111a4f9` | 52 |
| **SM645 `a5151d71`** | **56** |
| SM661 `ff32e4b3` | 57 |
| SM648 `a7ca992b` | 57 |
| SM644 `ea0f9b49` | 57 |
| SM659 `dd1d0f17` | 59 |
| 0.11.3 released | 58 |

Against the committed baseline: `verify_token_ms` 42.1 ms → 53.3 (v0.11.2,
1.27x) → 61.2 (0.11.3, 1.45x). `verify_password_ms` 130.1 → 136.8 → 150.3.

Three rounds of twenty calls varied by at most 1 ms per version, so the step is
larger than the noise.

# What it is not

Ruled out by measurement rather than by argument:

Machine load
: The first reading was taken while the release build held the machine. Re-run
  on an idle host (load 0.53) it reproduced at 61.2 ms against 63.6.

More I/O
: `strace -e openat` counts 72 opens, 26 inside the docroot, and the same eight
  files in the same proportions on both versions.

Compile cost
: The tool grew from 4,429 to 4,906 lines, worth about 1 ms of the 8.

Seeding on the hot path
: `_ensure_groups_seeded` IS reached by `verify-credential`, but it early-returns
  before `_migrate_admins_to_sysops` and `_ensure_manager_group_caps`, in both
  versions. Instrumented with a counter on a copy of the tool; neither sub is
  entered.

# What it is

No single regression. Ten commits each added one or two milliseconds of
per-request work, and the largest single step is SM645's capability top-up
(52 → 56). Nothing here is wrong on its own, which is the difficulty.

# CORRECTION: what this filing first said about the gate was wrong

Filed 2026-08-28 saying `tools/bench.pl` "fails the gate at 2x the baseline" and
that "the gate first objects somewhere around 0.12.x". Both are false, and the
correction changes what is worth doing.

Read from the tool rather than from memory of it:

- `$TOLERANCE = 1.25`, not 2. The 2x figure is from a comment describing an
  older rule.
- **Timings never fail the gate at all.** `# A duration: reported with its
  ratio, never failed on.` Only WORK COUNTERS exit 1 - SM342 made that choice
  deliberately, because a duration on a shared machine is not evidence and a
  gate that fails on one teaches people to re-run until it passes.
- So the gate is not going to object "around 0.12.x". It objected on this
  release: `verify_token_ms ... 1.45x <- beyond tolerance` is the tool working
  exactly as designed.

The original recommendation - a tighter per-op tolerance - would therefore
achieve nothing. The default is already 1.25, both ops are already past it, and
tightening a threshold that only changes a printed line does not change what
anybody does about it.

# What would actually catch this

The tool already contains the right instrument, used elsewhere: a WORK COUNTER.

`stats.pl --export` reports a `work` hash - bytes read, files read, days
written - and bench.pl fails on those, because *"A count is host-independent, so
this is not a slow machine."* That is the SM340 detector, and it is the reason
the stats regression could be caught while an 8ms drift cannot.

The auth path has no such counter. `verify-credential` opens the same 26 files
in both versions, so a file counter alone would not have caught this one - the
extra cost is CPU, not I/O. What would catch it is a counter of the work the
call actually does that grew: settings parses, group closure walks, capability
resolutions. Naming one is the piece of design work, and it is worth more than
another threshold.

Options, corrected:

1. **Instrument the auth path with a work counter**, the way stats.pl is
   instrumented, and let bench.pl fail on it. Host-independent, and it fails
   rather than prints. The most work and the only one that actually stops
   accretion.
2. **Re-capture the baseline.** Honest bookkeeping, and guarded: SM327 makes a
   re-capture that raises an op past tolerance refuse without
   `--accept-regression`. But it launders the drift and the next release starts
   from 58ms.
3. **Leave it reported.** The tool is behaving correctly; somebody has to read
   the line. That is what happened here - it was read, and it was investigated,
   which is the system working.

# Not blocking 0.11.3

The cut is correct and the gate passed. This is follow-up. Recorded now because
the measurement exists and will be expensive to reconstruct later.
