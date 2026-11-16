---
id: SM1452
title: "SM1452: t/integration/315 does not race the clock"
subtitle: "The maintenance test reads the clock once at load, to the minute, and checks Retry-After within two minutes of it; a slow run can fail it though the engine is right."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-16
raised-by: "the developer, reviewing the tests after SM1450"
area: tests
status-note: "OPEN. Target 0.17.x edge. Test only; no engine change. The same pattern as SM1450."
---

# What the test does

`t/integration/315-a-site-in-maintenance-sends-its-visitors-to-the-page.t` sets
`maintenance_until` when the file loads: the clock plus two hours, written to the minute, so up
to 59 seconds are dropped. Q1 then checks that the page's `Retry-After` is within 120 seconds of
7200.

# Why it can fail

The window left for the run is about 61 seconds, less the seconds dropped at load. Every site the
test builds before Q1, and every render in Q1, spends it. Under Devel::Cover a render takes tens
of seconds (SM1450), so a slow run reads a `Retry-After` more than 120 seconds short and fails.
It passed in the 0.17.0 gate, which ran without coverage.

# The request

R1
: Q1 bounds `Retry-After` by the clock read just before its request, as SM1450 did for
  t/unit/processor/185: the expected value is the seconds from that read to `maintenance_until`,
  and the tolerance covers the render, not the run.
