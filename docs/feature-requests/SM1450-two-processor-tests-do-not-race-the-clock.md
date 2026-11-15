---
id: SM1450
title: "SM1450: two processor tests no longer race the clock under Devel::Cover"
subtitle: "Under instrumentation a render takes tens of seconds; two tests read the clock at the wrong moment and failed the 0.17.0 coverage stage though the engine was right."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-13
raised-by: "the 0.17.0 --final gate's coverage stage, ruling 254"
area: tests
status-note: "SHIPPED (0.17.0) on n829. t/unit/processor/185 bounds a ttl: page's max-age by the clock read before the render; t/unit/processor/131 stamps its fresh file an hour ahead immediately before the If-Range request. Tests only; no engine change."
---

# What failed

The 0.17.0 `--final` gate's coverage stage ran the processor group under Devel::Cover. Two tests
that had passed in the plain suite minutes earlier failed there.

- `t/unit/processor/185-a-schedule-page-is-cached-until-its-state-changes.t` compared a `ttl:`
  page's max-age with `time` read after the render returned. The engine fixes max-age when it
  renders, so the bound was too tight by as long as the render took (about 40 s instrumented).
- `t/unit/processor/131-a-static-says-when-it-changed.t` stamped its "fresh" file a minute ahead,
  once, at the top of a file that runs for over a minute instrumented. By the If-Range request the
  date was more than a second behind the clock, and the engine rightly answered 206.

# What changed

185 reads the clock before the request. 131 sets the fresh file's date an hour ahead immediately
before the request that needs it. Each assertion still fails when the engine is wrong: checked by
scratch edits that removed the expiry clamp, loosened it by 60 s, and dropped the one-second rule.

# Not changed

`t/integration/315` has the same family of shape (a time read once at the top) and has not failed;
it is left for 0.17.x.
