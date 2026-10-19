---
id: SM1184
title: "SM1184: the bench counts the stats work on its fixture alone"
subtitle: "The cold and warm stats counts are taken before any timed run, so they read only the bench's own 30-day fixture and are the same on every run."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: lazysite developer agent, from the 0.15.10 release gate (n671)
area: release
status-note: "SHIPPED on n671: tools/bench.pl (counts before timed runs; the site's cache directory made), dist/config/bench-baseline.json work_cold_log_bytes 497392 -> 494010."
---

# What happened

The 0.15.10 gate (`tools/gate-main.sh --version 0.15.10`, 2026-10-19) passed
the suite (1433 files, 24839 tests) and stopped on the bench:

    WORK REGRESSION - the code is doing more than it did:
      work_cold_log_bytes: 500530, was 497392 - the code is doing MORE than it did
    release.sh: benchmark regression; not releasing.

`work_cold_log_bytes` is the number of access-log bytes the stats export reads
on a cold run. The bench writes a fixed fixture (30 days, 150 lines a day), then
ran its timed operations, then counted. The timed operations include 40 page
requests (20 cache hits, 20 misses), and each appends an access-log line to
today's file, so the cold count also read those 40 lines. Since SM1144 each
line carries the request's phase timings (`"tm":{...}`), about 78 bytes whose
length changes from run to run: 3,138 bytes across 40 lines. The count is meant
to be host-independent ("A count is host-independent, so this is not a slow
machine"), and it no longer was.

Release manager, 2026-10-19: "Count the fixture only".

# What shipped

- `tools/bench.pl` takes the cold and warm stats counts before any timed run,
  so they read only the fixture. The header comment that said the counters
  depend on what the timing runs wrote now says they read the fixture alone.
- The bench makes the site's `lazysite/cache` directory with the fixture, as an
  installed site has it. The stats export keeps its read offsets there
  (`_save_export_cache` writes nothing when the directory is missing); before
  the move the renders had made it, and without it a warm run re-read every
  byte and rewrote all 30 days.
- `dist/config/bench-baseline.json`: `work_cold_log_bytes` 497392 -> 494010,
  the fixture alone. The old figure included 3,382 bytes of the bench's own 40
  render lines from before SM1144. The warm counts (0 bytes, 0 files, 1 day
  written) and the timing baselines are unchanged.

# Evidence

Two full bench runs, pinned (`taskset -c 0 nice -n 19 ionice -c3`), after the
change: identical work counts.

    work_cold_log_bytes      494010
    work_cold_log_files          30
    work_users_tool_statements     3801
    work_warm_days_written        1
    work_warm_log_bytes           0
    work_warm_log_files           0

Before the cache directory was made, the same two runs gave warm 494010 bytes
and 30 days written, which is what found the second fault.
