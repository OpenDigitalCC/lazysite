---
id: SM763
title: "SM763: a render under instrumentation gets the time it needs"
subtitle: "The 0.13.4 coverage stage failed on a test that passes alone: the pandoc plugin's 20-second render ceiling, met under Devel::Cover at four jobs. The instrument changed the thing it measured."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-06 on claude/sm763-a-render-under-instrumentation-gets-the-time-it-needs for 0.13.4 (second build). plugins/pandoc.pl: $TIMEOUT_SECONDS is 90 when Devel::Cover is loaded or named in PERL5OPT, 20 otherwise - the rule Manager::Plugins already applies to its --describe budget."
---

# What happened

The first 0.13.4 build passed the uninstrumented suite (786 files, 12,612
tests) and failed the instrumented one on
`t/unit/plugins/41-a-composed-document-is-refused-not-quietly-shortened.t`,
subtests 2 and 4 - the two that render a real PDF (pandoc + XeLaTeX) and
expect `ok`. `coverage.sh --check` refuses a verdict on a suite that did not
pass, as it should, and the build stopped there. Nothing was tagged.

The test passes alone, plain and under Devel::Cover (34 s and 39 s for five
subtests). It passed in the 0.13.3 coverage run at the same job count.

# The cause, and its evidential grade

`plugins/pandoc.pl` gives a conversion 20 seconds (`$TIMEOUT_SECONDS`,
`alarm`). A render costs about 8 s of pandoc and XeLaTeX on this host when
nothing else is running; the coverage stage runs four instrumented jobs on six
cores, and Devel::Cover multiplies the CPU of every Perl process around them.
A render pushed past 20 s is refused as a timeout, and both failing subtests
are the ones that need a render to succeed.

**Inferred, not read:** the suite log carries the test's verdict and not its
diagnostics, so the refusal text was not seen. The inference rests on which
subtests failed, the ceiling, the load, and the test passing alone.

# What is built

The rule `Lazysite::Manager::Plugins` already applies to its `--describe`
budget (2 s plain, 30 s under Devel::Cover - "measurement must not alter
behaviour"): the pandoc plugin's ceiling is 90 s when Devel::Cover is loaded
or named in `PERL5OPT`, and 20 s otherwise. Production is unchanged.

# Not done

A general lint for "a timeout in a plugin follows the instrumentation rule"
would need a convention for naming such ceilings; two instances is not yet a
pattern. Recorded here so the third one finds this.
