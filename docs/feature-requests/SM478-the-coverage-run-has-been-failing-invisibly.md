---
title: "SM478: the instrumented suite has been failing, and the floors were measured from it anyway"
subtitle: "Twenty test files die under coverage with \"Can't locate X in @INC\" for modules that plainly exist. coverage.sh discarded the evidence, so the numbers in dist/config/coverage-floor describe runs that did not finish"
brand: plain
standard-margins: true
status: shipped
status-note: "CAUSE FOUND AND FIXED 2026-08-22/23. IT WAS ONE MISSING FLAG. The gate runs `prove -lr`; coverage.sh ran `prove -r`. Tests add `$FindBin::Bin/../lib` to @INC, which from t/lint resolves to t/lib - the TEST library, not the engine's - so the engine lib/ arrived only from -l. Without it eleven files died at `use Lazysite::...` with \"Can't locate X in @INC\", which reads as a missing module and is nothing of the kind: PERL REPORTS ANY FAILED open() THAT WAY. Confirmed with no instrumentation involved at all - `prove -r t/lint/17` fails, `prove -lr t/lint/17` passes - after two long runs spent on a memory hypothesis that the evidence never actually supported. THE @INC LINE WAS IN THE ERROR THE WHOLE TIME and named t/lint/../lib; reading it earlier would have saved both runs. SO ELEVEN FILES' COVERAGE HAS NEVER BEEN COUNTED, and the recorded floors were measured without them - the true numbers are most likely HIGHER than what is written down, not lower, which is the opposite of what the 2-job 're-baseline' appeared to show. THIS IS SM473 FROM THE OTHER SIDE: there the harness supplied something production did not (`prove -l` hid a missing @INC bootstrap); here the harness failed to supply what the OTHER harness does. Either way the harness was testing itself. ALSO FIXED: coverage.sh no longer discards the suite's output or swallows its exit code, --check refuses to compare an unmeasured suite to the floors (exit 3), and the suite log is written outside the staging clone - found by needing it, when the 0.10.26 build stopped and had deleted its own evidence. t/tools/60 pins all of it behaviourally against a miniature tree; the lib fixture lives in a SUBDIRECTORY because putting it directly in t/ made `../lib` land on the engine lib by accident and the sabotage could not fail it."
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
