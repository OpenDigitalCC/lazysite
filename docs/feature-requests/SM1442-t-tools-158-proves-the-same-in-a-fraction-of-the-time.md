---
id: SM1442
title: "SM1442: t/tools/158 proves the same in a fraction of the time"
subtitle: "The 0.16.12 gate failed only on t/tools/158, killed at the 300 s per-test deadline with no subtest run. The time was a cold-cache digest of the whole tree that coverage.sh makes before the cover step; the test now runs coverage.sh from a small fixture root."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "the 0.16.12 release gate (t/tools/158 killed after 300 s); release manager, ruling 244"
area: tests
status-note: "SHIPPED (PENDING) on n821. t/tools/158 runs the real tools/coverage.sh from a fixture root with no coverage-inputs.pl, so the 238 s cold-cache digest does not run: 0.26 s, was 283 s. All 9 assertions kept, deadline unchanged. Three sabotages each fail it. Test-only."
---

# What happened

The 0.16.12 gate failed only on `t/tools/158-a-killed-cover-is-not-a-test-failure.t`: "child bash
... was still running after 300s and was killed", no subtest run. The test had not changed since
0.16.11. Alone it passed its 9 tests in 273 s wall.

# Where the time went

Measured under the heavy lock, one machine, nice 19:

- `perl tools/coverage-inputs.pl` (the digest `coverage.sh` takes of every input that decides
  coverage, before the report step and even with `LAZYSITE_COVER_FORCE=1`): 238.5 s wall cold,
  0.45 s warm. The cache is `tmp/coverage-inputs-cache.sto`; the gate's staged tree has none.
- The unchanged test: 254.6 s at the 0.16.10 release commit, 282.8 s at main with an empty
  cache. It grew about 11 percent over two releases and was never far from the deadline.

# The change

`t/tools/158` copies the real `coverage.sh`, `heavy-lock.sh` and `preflight.sh` into a fixture
root and runs `coverage.sh --check` from there. With no `coverage-inputs.pl` the digest is empty
and the stage goes on to the cover step, which is what the test is about. As a side effect the
test no longer takes `.coverage.lock` in the real tree. The 9 assertions are the same; nothing is
skipped and the deadline is not raised.

# Test

The new 158 runs in 0.26 s. Against a copy outside the tree, with the unsabotaged copy passing:

- `coverage.sh` stops recognising 137 and 143 as killed: tests 1 to 6 fail.
- `coverage.sh` calls an ordinary cover failure killed: tests 7 and 8 fail.
- `release.sh` loses the "verdict KILLED" line: test 9 fails.
