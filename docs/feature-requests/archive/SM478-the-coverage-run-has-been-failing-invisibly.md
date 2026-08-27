---
title: "SM478: the instrumented suite has been failing, and the floors were measured from it anyway"
subtitle: "Twenty test files die under coverage with \"Can't locate X in @INC\" for modules that plainly exist. coverage.sh discarded the evidence, so the numbers in dist/config/coverage-floor describe runs that did not finish"
brand: plain
standard-margins: true
status: shipped
status-note: "CAUSE FOUND AND FIXED 2026-08-22/23. IT WAS ONE MISSING FLAG. The gate runs `prove -lr`; coverage.sh ran `prove -r`. Tests add `$FindBin::Bin/../lib` to @INC, which from t/lint resolves to t/lib - the TEST library, not the engine's - so the engine lib/ arrived only from -l. Without it eleven files died at `use Lazysite::...` with \"Can't locate X in @INC\", which reads as a missing module and is nothing of the kind: PERL REPORTS ANY FAILED open() THAT WAY. Confirmed with no instrumentation involved at all - `prove -r t/lint/17` fails, `prove -lr t/lint/17` passes - after two long runs spent on a memory hypothesis that the evidence never actually supported. THE @INC LINE WAS IN THE ERROR THE WHOLE TIME and named t/lint/../lib; reading it earlier would have saved both runs. SO ELEVEN FILES' COVERAGE HAS NEVER BEEN COUNTED, and the recorded floors were measured without them - the true numbers are most likely HIGHER than what is written down, not lower, which is the opposite of what the 2-job 're-baseline' appeared to show. THIS IS SM473 FROM THE OTHER SIDE: there the harness supplied something production did not (`prove -l` hid a missing @INC bootstrap); here the harness failed to supply what the OTHER harness does. Either way the harness was testing itself. ALSO FIXED: coverage.sh no longer discards the suite's output or swallows its exit code, --check refuses to compare an unmeasured suite to the floors (exit 3), and the suite log is written outside the staging clone - found by needing it, when the 0.10.26 build stopped and had deleted its own evidence. t/tools/60 pins all of it behaviourally against a miniature tree; the lib fixture lives in a SUBDIRECTORY because putting it directly in t/ made `../lib` land on the engine lib by accident and the sabotage could not fail it."
---

# What was failing

Eleven test files, every run, exiting 2 having run **zero** tests. The error:

```
Can't locate Lazysite/Manager/Common.pm in @INC
  (@INC entries checked: /srv/projects/lazysite/t/lint/../lib  ...)
```

**The answer was in that line the whole time.** `t/lint/../lib` is `t/lib` --
the *test* library. Not `lib/`. The engine's modules were never on `@INC`.

Tests write `use lib "$FindBin::Bin/../lib"`, which from a subdirectory of `t/`
lands on `t/lib`, and rely on **`prove -l`** to supply the engine's `lib/`. The
gate runs `prove -lr`. `coverage.sh` ran `prove -r`.

One flag.

# The wrong turning, since it cost more than the fix

`Can't locate X in @INC` reads as a missing module, and Perl prints it for
**any** failed `open()` -- it does not distinguish "not there" from "could not
open it". Taking the wording at face value, the modules obviously existed, so
the failure looked like resource pressure: it varied slightly between runs, it
never reproduced in isolation, and it never reproduced in a group of five.

That bought a 4-job instrumented run and a 2-job one -- over two hours -- to
test a memory hypothesis, on evidence that never supported it. Descriptors were
not short (524,288). Inodes were not short (43%). Memory bottomed at 1089 MB,
tight but not exhausted, and halving the jobs changed nothing.

It reproduces in one second with no instrumentation at all:

```
prove -r  t/lint/17-dav-shared-parity.t   # FAIL, 0 tests
prove -lr t/lint/17-dav-shared-parity.t   # PASS, 9 tests
```

**Read the `@INC` list before theorising about why a file could not be opened.**

# What it means for the floors

Those eleven files have never run under coverage, so their coverage has never
been counted, for as long as that line has existed. The recorded floors were
measured without them.

So the true numbers are most likely **higher** than what is written down -- the
opposite of what the 2-job run appeared to show. The 38.6% that nearly became a
new baseline was never a measurement of anything.

This may also be what the floor file calls manager-api's branch measurement
*"swinging 56.6% - 80.7% on near-identical code, a merge-timing artifact of the
instrumented subprocess children"*. It may be a different subset of the suite
dying each time.

# The same lesson as SM473, from the other side

SM473: the harness supplied something production did not. `prove -l` put `lib/`
on `@INC`, so a missing bootstrap in the processor passed every test and failed
every real install.

SM478: the harness failed to supply what the *other* harness does.

Either way the harness was testing itself, and in both cases the symptom
appeared in the product rather than in the harness.

# What the measurement then found in the product

Getting one clean instrumented run took four attempts, and each obstacle was a
real defect rather than an inconvenience:

```datatable
columns: What stopped it | What it actually was
widths: 6.4cm | X
bold: 1
tone: medium
---
Eleven files "missing modules" | `coverage.sh` ran `prove -r`, not `-lr`
`users.pl` at 59% | one `BAIL_OUT` stopped the whole suite; 84 files never ran
A test failing at 00:51 | a fixture that straddles UTC midnight for 90 minutes a day
"processor returned no CGI response" | Devel::Cover instrumenting tempdir copies of a CGI it then broke
A control asserting a stampede | instrumentation serialises the processes it needs to collide
`id=lazysite` missing from the plugin list | a 2-second `--describe` budget, and a plugin that overruns is dropped **in silence**
```

The last one is a product defect in its own right and would never have been
found any other way. `action_plugin_list` gives each plugin two seconds to
describe itself and drops it with `next if $@` -- nothing written anywhere. On
a loaded host an operator watches a plugin vanish from the Plugin Manager with
no way to discover why. It now says so in the log, and the budget scales under
instrumentation, because measurement must not change behaviour.

# What else was fixed alongside

- `coverage.sh` no longer discards the suite's output or swallows its exit
  code, and reports the result pass or fail.
- `--check` refuses to compare an unmeasured suite to the floors (exit 3):
  not 0, which would pass a release gate on nothing, and not 1, which would
  blame coverage for something that is not coverage.
- The suite log is written outside the staging clone. Found by needing it --
  the 0.10.26 build stopped at exit 3 and had deleted its own evidence.
- `t/tools/60` pins all of it against a miniature tree. Its lib fixture lives
  in a **subdirectory**, because directly in `t/` the `../lib` lands on the
  engine lib by accident, the test passes with or without `-l`, and the
  sabotage cannot fail it. Which is what the first version did.
