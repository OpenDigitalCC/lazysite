---
title: "SM478: the instrumented suite has been failing, and the floors were measured from it anyway"
subtitle: "Twenty test files die under coverage with \"Can't locate X in @INC\" for modules that plainly exist. coverage.sh discarded the evidence, so the numbers in dist/config/coverage-floor describe runs that did not finish"
brand: plain
standard-margins: true
status: partial
status-note: "FOUND 2026-08-22 while carrying out D-1 (pin coverage to 2 jobs and re-baseline the floors). The re-baseline reported 38.6% statement for lazysite-auth.pl against the 82.1% recorded baseline, and those numbers were one commit away from being written in as the new floor - which would have RATCHETED THE FLOORS DOWN, the one thing that file forbids in as many words. THE GIVEAWAY WAS THE CLOCK, NOT THE NUMBERS: 465 seconds against 270 for the same suite uninstrumented, and Devel::Cover does not cost 1.7x. FIXED SO FAR (c1c2feb): coverage.sh no longer runs `prove >/dev/null 2>&1 || true` - the suite's output is kept, its exit code recorded, the result reported pass or fail, and `--check` REFUSES to compare an unmeasured suite to the floors (exit 3, not 0 which would pass a release gate on nothing, and not 1 which would blame coverage for something that is not coverage - SM444 one layer further in). 076b442 moves the suite log outside the staging clone, found by needing it: the 0.10.26 build stopped at exit 3 and had deleted its own evidence. STILL OPEN: the underlying failures, and what the floors actually are. THE 0.10.26 CUT IS BLOCKED ON THIS - by the new refusal working, which is the correct outcome and not one to route around: weakening the gate would re-hide exactly what it was built to surface."
---

# What fails

Twenty test files, in a clean staged clone at 4 jobs, most exiting 2 having run
**zero** tests:

```datatable
columns: Symptom | Detail
widths: 6cm | X
bold: 1
tone: medium
---
The error | `Can't locate Lazysite/Data/Query.pm in @INC`
The `@INC` it printed | contains the right absolute `lib/` directory
The file | is present, readable, and unchanged
In isolation | **passes** under the same instrumentation
In a group of five | **passes**
In the full suite | fails, and a different set fails each run
```

The victims are random and spread across unrelated modules -- `Tables.pm`,
`Private.pm`, `Manager/Common.pm`, `Util.pm`, `DomainRewrites.pm` -- one to
four occurrences each, changing between runs.

**Perl reports any failed `open()` as "Can't locate".** It does not distinguish
a missing file from a file it could not open, so this wording is a red herring:
nothing is missing. Something is failing to open files under load.

Not descriptors: the limit is 524,288. Not inodes: `/srv` peaked at 43% used.
Memory is the remaining candidate -- the box has 9.7 GB with 1 GB of swap, and
an instrumented 4-way run was measured at ~3.9 GB before this work started.

# Why nobody knew

```
prove -j"$JOBS" -r t/ >/dev/null 2>&1 || true
```

Output discarded, exit code swallowed. A run that lost twenty files produced a
report indistinguishable from a healthy one, only with lower numbers -- and the
floor check takes the **best-covered** row when a file appears at several
paths, so the floors were met anyway from whichever copy happened to survive.

That is very likely what `dist/config/coverage-floor` describes as
*"manager-api's BRANCH measurement swings run-to-run (56.6% - 80.7% observed on
near-identical code) - a merge-timing artifact of the instrumented subprocess
children"*. It may not be a merge-timing artifact at all. It may be a different
subset of the suite dying each time.

# What this filing cannot yet say

Whether the recorded floors are achievable on a run that completes. They were
measured the same way, so they inherit the same doubt -- upward or downward is
unknown until one clean run exists.

# Next

A 2-job instrumented run on a quiet box, sampled, was running when this was
filed. If the failures thin out or vanish, D-1's job-count pin is not merely a
saving of ~620 MB against ~3.9 GB -- it is the fix, and the re-baseline can
then be taken from a run that finished.
