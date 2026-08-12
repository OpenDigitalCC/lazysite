---
title: "Coverage series"
subtitle: "One row per release cut. Started 2026-08-12 because a drift rate cannot be measured backwards."
brand: plain
standard-margins: true
---

# Coverage series

## Why this file exists

SM269 phase 0 established that **coverage is 92% of the release gate's
wall-clock**, at a 12.4x instrumentation multiplier. [[SM280]] asks whether
progressive coverage - measuring only what changed - can move that hour, and the
question it has to answer first is *how fast does coverage actually drift
between cuts?* A rate needs a series, and a series cannot be reconstructed after
the fact: the numbers exist only in the gate output of a run that has already
been discarded.

So this file is appended at every cut, starting from the first one after the
question was asked. It is deliberately not generated - the gate prints these
numbers and a person records them, which takes ten seconds and is the only
reason the series will exist at all.

**What to record:** the per-CGI statement and branch percentages from the
`coverage: ...` block at the end of `make tier-release`, plus the suite size
from the `Files=… Tests=…` line. Record the run that gated the cut, not a later
one.

## The series

```datatable
columns: Release | Suite | dav | processor | manager-api | auth | mcp | oauth | users | bundle-apply
widths: 2.2cm | 2.4cm | X | X | X | X | X | X | X | X
bold: 1
tone: medium
---
0.10.7 | 331 files\
7100 tests | 93.5\
74.3 | 88.0\
73.3 | 80.8\
65.5 | 82.5\
64.6 | 91.0\
65.7 | 99.3\
94.8 | 91.9\
74.7 | 89.8\
65.0
```

Each cell is **statement % over branch %**. Floors are 75/62 for `dav`,
`processor`, `oauth`, `users` and `bundle-apply`, and 75/60 for `manager-api`,
`auth` and `mcp`.

## Earlier points, from release records rather than from a gate log

Recorded for context, not as part of the series - they are whole-tree figures
from the release notes of the day and are not comparable cell-by-cell with the
per-CGI table above.

0.10.5 (2026-08-10)
: 92.8% statements, 62.7% branches across the tree; 321 files / 6842 tests.
  Weakest modules called out at the time: `Notify.pm` 56.7%, `Backups.pm` 69.6%.

0.10.7 (2026-08-11)
: `Notify.pm` raised to 89.6% by SM231. `lazysite-dav.pl` is the release's
  most-changed CGI (SM284) and its branch coverage rose with the new
  behavioural test - which is the pattern SM280 wants to be able to see
  without paying 80 minutes to find it.

## What would make this file redundant

A gate that records its own numbers. That is a reasonable thing to build and
deliberately not built yet: the value here is the series, and a person appending
a row proves the series is wanted before any tooling is written for it. If this
file is still being maintained by hand in six months, automate it.
