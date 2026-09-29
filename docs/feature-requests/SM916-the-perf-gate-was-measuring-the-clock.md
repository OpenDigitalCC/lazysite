---
id: SM916
title: "SM916: the perf gate's work counter was measuring the clock, and it refused a release for it"
subtitle: "tools/bench.pl reports work_cold_log_bytes - the bytes the stats ingest reads from a fixture of thirty days of visitor logs - and treats any change as WORK, on the stated grounds that \"a count is host-independent, so this is not a slow machine\". The fixture's timestamps were floats taken from Time::HiRes, so its SIZE depended on how many digits the wall clock's fractional part happened to need: exactly 4500 bytes per decimal digit, across 4500 lines that all share one timestamp. Measured 2026-09-29: the 0.15.0 baseline records 519892, and the commit it says it was captured at reproduces 524392 - stably, twice - so the gate was refusing the 0.15.1 cut over one digit of the clock."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-29 on claude/sm916-bench-fixture-reads-the-clock. The fixture writes int($when - $i), which is what the engine has always written: lazysite-processor.pl's _access_record builds '{\"t\":' . time() and the processor does not import Time::HiRes, so no real access log has ever carried a fractional timestamp. The counter is now stable - 497392 on three consecutive runs - and the baseline is re-captured against it. t/lint/159 pins both halves of the agreement, the fixture's int() and the processor's bare time(), because the fixture was not merely unstable but UNLIKE the log it stands in for. Four sabotages, four caught. NOT DONE, and deliberately: the other work counters have not been audited for the same shape, and work_cold_log_bytes is the only one whose units are bytes rather than operations - it is the only one that could have this defect, but that is reasoning rather than measurement, so it is written here as an open question rather than a clean bill."
raised: 2026-09-29
raised-by: engine agent, while preparing the 0.15.1 build
area: release
---

# How this was found

By the 0.15.1 build refusing, and then by not believing its reason.

`tools/release.sh build 0.15.1` stopped at `bench.pl --check`, which reported a
WORK REGRESSION on two counters and said, in its own words, "A count is
host-independent, so this is not a slow machine". The obvious reading was that
this release had made the engine do more, and the obvious remedy was the one the
0.15.0 cut used a day earlier: move the baseline and describe what grew.

Two counters moved, and they turned out to be different in kind.

# The one that was real, and is not a defect

`work_users_tool_statements` went 3342 -> 3354. That counter is
`_statement_count("$ROOT/tools/lazysite-users.pl")`, which is a count of
non-blank, non-comment, non-POD LINES in the source file - a code-size proxy,
not a runtime measure.

Walking every commit since the baseline shows one step and no drift:

    5cdca707  3342  (0.15.0 is cut)
    e6fd5b7f  3354  +12  SM485: a notice can name a person, and reach them by mail

SM485 added `notify_email` to `cmd_set` and the `%SELF_SERVICE` map. Twelve
lines, one commit, exactly where the work was done. Expected growth.

# The one that was the clock

`work_cold_log_bytes` went 519892 -> 524392, a difference of 4500.

The bench fixture is thirty daily log files of 150 lines each: 4500 lines. So
the difference is EXACTLY ONE BYTE PER LINE, which is not what real growth looks
like.

`tools/bench.pl` imports `time()` from `Time::HiRes` for its timing helper, so
the `$now` the fixture is built from is a float, and every line was written with
`t => $when - $i` - a float straight into JSON. JSON renders a float to as many
digits as the value needs. Measured:

    integer                 9 bytes of timestamp
    ...500                 11
    ...25                  12
    ...125                 13
    ...9999                14
    ordinary 5-digit       15

Every line in the fixture derives from the same `$now`, so they all take the
same width and move together: one extra digit is 4500 bytes, exactly. Building
the fixture at controlled fractional parts reproduces the ladder - 494010,
503010, 507510, 512010, 516510, 521010 - each rung 4500 apart.

# The measurement that settles it

Not "the numbers look explainable". The baseline claims to have been captured at
`c0ec29dd`. Checking that commit out and running bench there twice gives:

    run 1   cold_log_bytes=524392   cold_log_files=30   stmts=3342
    run 2   cold_log_bytes=524392   cold_log_files=30   stmts=3342

`stmts` matches the baseline. `cold_log_bytes` does not, and is stable at a
value the baseline does not contain. **The recorded number is not a property of
the tree it was recorded from.** It is what the clock read on 2026-09-28, and
519892 is a value that occurs only when the fractional second happens to render
one digit short - roughly one run in ten. The gate was therefore refusing about
nine cuts in ten for a reason belonging to neither the code nor the host.

This is also the likeliest explanation of the 0.15.0 cut's own bench refusal
(N23), which was resolved by moving the baseline. That move recorded a lucky
number and set the next release up to fail.

# Why the fix is int() and not a tolerance

A tolerance on a work counter would give back the thing the counter exists to
provide: `work_*` is the half of this gate that is supposed to be exact, and
SM342 added it precisely because timings alone could not tell a slow machine
from more work. Widening it to cover clock noise would make every work counter
approximate to fix one that was wrong.

The engine has always written an integer. `_access_record` in
`lazysite-processor.pl` builds its line as `'{"t":' . time()` and the processor
does not import `Time::HiRes`, so `time` there is `CORE::time`. No access log
in the field has ever held a fractional timestamp.

So the fixture was not only unstable, it was **unlike the thing it stands in
for** - 27000 bytes of it, 5.4%, was timestamp width rather than traffic, and
the ingest cost it was guarding was overstated by that much. `int()` fixes the
instability and the unrepresentativeness in the same character, which is why
there is no second change here.

# What is gated

`t/lint/159` pins both sides, because either alone would break the agreement:

  - the fixture writes `t => int(...)`, and bench.pl still imports a float
    `time()` - so a reader who deletes the "redundant" int() meets a test that
    explains why it is load-bearing;
  - the processor still writes a bare `time()`, and still does NOT import a
    float `time()` - so if that import ever arrives, `_access_record` needs its
    own `int()` first, and the lint says so rather than letting every visitor
    log quietly grow.

Sabotaged four ways, one per assertion; four caught, tree restored, gate green.

# What this does not cover

The other five work counters were not audited. `work_cold_log_bytes` is the only
one measured in bytes rather than operations, and a count of operations cannot
acquire digits from the clock - but that is an argument, not a measurement, and
it is recorded here as such. If a work counter refuses a future cut, this filing
is the first thing to re-read.
