---
id: SM1230
title: "SM1230: coverage fits around the night's other work"
subtitle: "The 01:30 cover-once was refused on swap other agents' work had left in use. Swap no longer refuses; the run is nice 19, ionice idle, 2 jobs, starts at 22:00, has no time limit and resumes by group."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager, 2026-10-20 (tmp/rulings-2026-10-20.md, Stable gate (218) and coverage (337)), after the 01:30 cover-once was refused"
area: tools
status-note: "SHIPPED (PENDING) on n713: preflight no longer refuses on swap in use (MemAvailable under 5 GB still does); stand-alone coverage runs nice 19, ionice idle, 2 jobs, one at a time, resuming by group. Test t/tools/205."
---

# What happened

tmp/overnight/cover-2026-10-20.txt: the 01:30 cover-once ended `coverage.sh exit 3`,
"swap in use 2904 MB is over 1024 MB and MemAvailable 7075 MB is under 7168 MB".
The 7168 MB was the 5 GB floor plus 2 GB slack (tools/preflight.sh). The host carries
more than 3 GB of swap all day from other agents' work.

The ruling: "this might not be a problem - other agents are busy doing important
things, so the coverage should fit in with that. probably a refuse is the wrong
solution, maybe start earlier and run longer, from 10pm."

# What shipped

- tools/preflight.sh: swap in use is a note for HEAVY and SUITE alike. The floor is
  MemAvailable 5 GB (SM1083's figure for one worker). The repo records no per-group
  peak, so the figure is not lowered; a lower one needs a measured peak.
- tools/coverage-parts.sh, run alone: re-executes under `nice -n 19 ionice -c3`,
  `LAZYSITE_COVER_JOBS` defaults to 2, a second start exits 2 at once naming the
  holder (`.run.lock` in the pass store), no time limit. Each group's pass is recorded
  as it ends, so a later run reuses the finished groups. Inside the gate (HEAVY_HELD)
  nothing changes.
- Schedule: the cover-once line is in the operator's crontab, outside the repo; see
  the batch report for the line.
- t/tools/205 drives the driver with a stand-in runner; nothing is instrumented.
