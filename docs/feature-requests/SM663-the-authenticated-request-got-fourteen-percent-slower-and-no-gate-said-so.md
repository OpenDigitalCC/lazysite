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

# Why it needs a decision rather than a fix

`tools/bench.pl` fails the gate at 2x the baseline, and its own comment on SM327
says a 2x tolerance permits unbounded accretion. This release is the argument
made concrete: every commit passed, and the path is 1.45x. At this rate the gate
first objects somewhere around 0.12.x, by which point the cause is thirty
commits deep.

Options, in the order they seem worth considering:

1. A per-op tolerance for the auth ops in the baseline's `tolerances` map -
   tight enough (say 1.15x) that the next milliseconds argue for themselves.
   Cheapest, and it turns accretion into a conversation at the commit that
   causes it.
2. Re-capture the baseline and accept 58 ms as the new normal. Honest, but it
   launders the accretion and the next release starts from a worse floor.
3. Find the milliseconds. A cold-start CGI at 58 ms is mostly startup; the work
   is probably worth doing once, properly, rather than per-commit.

(1) and (3) are complementary. (2) alone is how the number gets to 80 ms.

# Not blocking 0.11.3

The cut is correct and the gate passed. This is follow-up. Recorded now because
the measurement exists and will be expensive to reconstruct later.
