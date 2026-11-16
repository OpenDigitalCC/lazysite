---
id: SM1449
title: "SM1449: a gate stopped part way resumes where it stopped"
subtitle: "The suite stage records a pass for its tree, the large coverage groups are split, and the cheap groups run first, so a killed gate loses minutes, not hours."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-13
raised-by: "the release manager, after the 0.17.0 stable gate was stopped part way"
area: release
status-note: "OPEN. Target 0.17.x edge. Tools only (tools/gate-main.sh, tools/coverage-groups.pl, tools/coverage-parts.sh); no engine code. Since ruling 256 (SM1451) coverage runs for certified only, so R1 is the request every gate gains from; R2 and R3 matter for a certified gate."
---

# What happened

The 0.17.0 `--final` gate was stopped on 12 Nov 2026 by the host, short of memory while the
session was idle, about 2.5 hours into its coverage stage. The rerun on the same tree began again
from the start: the suite stage (about 33 minutes) and every coverage group.

# What resumes today

Each coverage group records its pass the moment it ends, keyed by the digest of its own inputs
(`coverage-passes/GROUP/DIGEST.json`), and a later run on the same inputs reuses it. The stop
came in the first group measured, `processor`, so no group had finished and nothing was reused.

# What does not

1. **The suite stage records nothing.** `tools/gate-main.sh` runs the whole suite on every gate,
   even on a tree it has already passed.
2. **The `processor` group is one long run.** It is a single `prove` over some two hundred
   integration and unit tests, instrumented, and takes hours. A stop inside it loses all of it.
3. **The longest group runs first.** A stop late in the stage loses less if the cheap groups
   have already recorded.

# The requests

R1
: The suite stage records a pass keyed by the tree it ran on (the tree id, not the commit, as
  the release manager lands by rebase) and the gate's options. A gate on a tree with a recorded
  pass says so and skips the suite. A failed or stopped suite records nothing.

R2
: Any coverage group that takes over an hour is split by area into groups that each take well
  under an hour. Each new group keeps its own digest, cover DB, floors and record, as today.

R3
: Groups run cheapest first, by the recorded time of their last pass.

# To settle when built

- That a reused suite pass and a reused group are named in the gate's digest, so the evidence for
  a release says what was run and what was reused.
- That a split changes no floor: the files each group gates, taken together, are the same set.
- That a damaged or unreadable record is a refusal, not a pass (ruling 206), and that no record
  means measure.

# Not decided

No design, no code. This filing records the request so it is not lost.
