---
id: SM1451
title: "SM1451: the coverage stage runs for certified only; a stable gates like a beta"
subtitle: "Coverage no longer blocks a stable release. It runs for a certified cut, when forced, or on demand as advice."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-15
raised-by: "the release manager, ruling 256"
area: release
status-note: "SHIPPED (0.17.0) on n830. release.sh and gate-main.sh run coverage for --certified only (or LAZYSITE_COVER_FORCE=1); a stable receipt says coverage=not run and build accepts it. Replaces SM1083's 'stable only'. t/tools/104, t/tools/168, docs/DEVELOPER.md."
---

# Why

The 0.17.0 stable was held for three days by the coverage stage alone. The suite and bench passed
every time; each failure was the stage's own: two tests that raced the clock under instrumentation
(SM1450), and repeated memory kills in the Devel::Cover merge of the processor group. In its history
the stage has found no engine fault, and every coverage filing is about the stage itself. A stable
that cannot ship its fixes is the larger risk (ruling 256, 15 Nov 2026).

# What changed

- `tools/release.sh` runs the coverage stage for the certified channel only, or on any channel with
  `LAZYSITE_COVER_FORCE=1`. A stable receipt says
  `coverage=not run (channel stable; certified only, ruling 256)`, and build accepts it; a certified
  build still refuses a receipt with no coverage, and names `--certified` as the way to get one.
- `tools/gate-main.sh` starts its guard in HEAVY mode for certified only.
- `--final` keeps the release-material lints and the download/ commit.
- `tools/coverage.sh` stays, on demand, as advice.

# Tests

`t/tools/104` proves edge, beta and stable gates run no coverage and a certified gate measures; a
certified build refuses a receipt that ran none. `t/tools/168` proves the certified guard notes
swap rather than refusing.
