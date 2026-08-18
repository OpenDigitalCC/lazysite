---
title: "SM370 - the recount dry-run test fails intermittently"
subtitle: "One failure in three full-gate runs on an unchanged tree, in the subtest covering the verb that overwrites the only durable record a site has. It passed on re-run and on three targeted runs. Nobody knows yet whether the flake is in the test or in the thing it tests."
brand: plain
status: candidate
status-note: "FILED 2026-08-18 rather than shrugged off. It failed once during a gate run on a branch whose changes are in Lazysite::Manager::Themes and lazysite-mcp.pl - nothing that touches the stats plugin - and passed on the immediate re-run, on three consecutive runs of t/unit/plugins, and on a second full gate. So it is not attributable to the change that was in flight, and that is exactly why it needs a number: an intermittent nobody can attribute is an intermittent nobody will chase, and this one sits on --recount."
---

# What happened

```
t/unit/plugins/09-the-durable-store-can-be-repaired.t
  Failed test: 5    'the recount reports before it writes'
```

Same tree, immediately afterwards: pass. Three consecutive runs of
`t/unit/plugins`: pass. A second full gate, 412 files and 7,877 tests: pass.

# Why it is worth a filing rather than a re-run

**Of all the subtests to flake, this is the one.** `--recount` rewrites the
durable per-day store, and subtest 5 is the guard that it reports before it
writes - that a dry run is genuinely dry. [[SM339]] built the dry-run default
precisely because "a verb that acts by default is the wrong shape however good
the arithmetic is."

So the two candidates are not equally comfortable:

the fixture is fragile
: likely, and harmless. `$YEST = time() - 86400` with events at `+1..4`
  seconds, and `days_the_logs_cover` derived from a retained-log window. A run
  crossing an hour or day boundary at the wrong moment could plausibly change
  what the window covers.

the recount is not deterministic
: unlikely, and would matter a great deal. If what a dry run reports depends on
  when it runs, the figure an operator reads before authorising a rewrite is not
  the figure they get.

Nothing here distinguishes them. That is the finding.

# What would settle it

Run the subtest in a loop with the clock advanced across an hour and a day
boundary, and against a fixed epoch rather than `time()`. If a pinned clock
never flakes, it is the fixture; if it still does, it is the verb, and that is a
different filing with a different urgency.

The wider point is worth stating too: this suite anchors several fixtures to
`time()`, and [[SM336]]'s session work already hit one - a fixture using
`time()-86400` whose gap crossed midnight into a different day file. Same
family.

# Verification

- The subtest passes with the clock pinned, run repeatedly across synthesised
  hour and day boundaries.
- Or it does not, and `--recount`'s dry-run report is shown to depend on when it
  is called.

# Related

[[SM339]] (the recount and its dry-run default), [[SM343]] (the durable day
store this repairs), and [[SM336]] (a fixture anchored to `time()` that crossed
midnight, which is the same family of fragility).
