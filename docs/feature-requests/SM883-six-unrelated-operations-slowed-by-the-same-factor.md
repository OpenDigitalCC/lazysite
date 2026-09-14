---
id: SM883
title: "SM883: six unrelated operations slowed by nearly the same factor, and nothing failed"
subtitle: "Between the 2026-09-10 baseline and 0.14.1, every timed operation in the perf gate moved 1.20-1.27x - render, password verification, token verification and the stats export alike. It is reproducible on an idle host, so it is not load. Durations are reported and never failed on, so it shipped inside 0.14.0 unexamined, and the 0.14.1 re-baseline has now made it the new normal. This filing exists so that re-baselining moved a number rather than closing a question."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-14 during the 0.14.1 cut. The build was blocked by the WORK counter (tools/lazysite-users.pl 3267 -> 3303, a strict ratchet, and all 36 statements were 0.14.1's own new behaviour). Clearing it needed bench.pl --baseline, which SM327 refuses over a timing regression without --accept-regression - so the drift had to be looked at before the release could move. The release manager accepted both and asked for the drift to be filed rather than buried. MEASURED, NOT INFERRED: run once during a busy period and again at load 0.63 and 0.32 with materially identical results, so it is the code or the machine, not contention. NOT ATTRIBUTED: the window is 2026-09-10 to 2026-09-13, which is 0.14.0's own, and nobody has bisected it."
---

# What was measured

`tools/bench.pl --check` against the baseline captured 2026-09-10 on `ai-dev`
(perl v5.40.1), run on the same host:

| operation | baseline | 0.14.1 | ratio |
| --- | --- | --- | --- |
| `render_cache_hit_ms` | 65.9 | 82.5 | 1.25x |
| `render_miss_ms` | 89.8 | 114.3 | 1.27x |
| `stats_export_ms` | 588.8 | 707.5 | 1.20x |
| `verify_password_ms` | 85.8 | 104.0 | 1.21x |
| `verify_token_cli_ms` | 60.6 | 73.0 | 1.21x |
| `verify_token_ms` | 0.5 | 0.6 | 1.26x |

**Every timed operation, and all within seven percentage points of each other.**

# Why it is worth a filing rather than a shrug

**It is not host load.** The first reading was taken on a host that had been
running full suites all day, which is the obvious explanation and the wrong one:
a second run at load 0.63, and the baseline capture itself at load 0.32, gave
materially the same numbers.

**It is not one slow function.** Rendering a cached page, rendering a miss,
verifying a password, verifying a token and exporting stats do not share an
implementation. A uniform factor across unrelated paths points at something
every path pays - a module loaded at startup, a store read on each call, an
interpreter or library change - or at the machine itself having changed.

**Nothing failed, by design.** `bench.pl` reports durations with their ratio and
never fails on them, deliberately: a millisecond figure is about the machine.
Only the `work_*` counters are a ratchet. So this drift accumulated, shipped in
0.14.0 and would have shipped in 0.14.1 with no gate ever raising its voice.

# What the re-baseline did, and did not, settle

The 0.14.1 cut re-captured the baseline (`--baseline --accept-regression`,
2026-09-14) because the work counter was blocking and the tool will not
re-capture over a timing regression silently - which is SM327 working exactly as
written.

That decision was taken with the drift visible and named. **It makes the slower
numbers the new definition of correct, which is precisely what SM327 warns
about** - so it is recorded here rather than left to be rediscovered against a
baseline that no longer remembers. The next drift will be measured from 82.5ms,
not 65.9ms.

# Where to start

- **Bisect 2026-09-10 to 2026-09-13.** That window is 0.14.0's own, and it is
  short. The baseline sat exactly on `work_users_tool_statements: 3267` at
  v0.14.0, so the release is well bounded on both sides.
- **Check the machine before the code.** Twenty-nine days of uptime, a disk at
  90%, and a host that has been building releases all week. A uniform factor is
  as consistent with the environment as with the engine, and that is cheaper to
  rule out.
- **`verify_token_ms` is sub-millisecond** (0.5 -> 0.6) and should carry the
  least weight of the six: at that scale the ratio is noise-dominated. The
  informative ones are `render_miss_ms` and `stats_export_ms`, which are large
  enough for 1.2x to be real work.

# Related

[[SM327]] (why a re-capture over a regression has to be stated), [[SM342]] (a
duration is about the machine, a count is about the code).
