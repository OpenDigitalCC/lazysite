---
id: SM1088
title: "SM1088: the swap margin guards the coverage stage only"
subtitle: "A gate that runs no coverage stage starts on the memory threshold alone; stale swap no longer refuses it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: release
status-note: "SHIPPED on n601: tools/preflight.sh SUITE mode, tools/gate-main.sh; t/tools/156, t/tools/168."
---

# What happened

The 0.15.6 edge gate was refused at its start check:

    gate-main: SKIPPED - preflight: not now - swap in use 2521 MB is over
    1024 MB and MemAvailable 6665 MB is under 7168 MB

The release manager's threshold, 5 GB available, was met. The extra 2 GB
margin when swap is in use was added in n595 for the coverage stage, the job
whose merge was killed twice for memory. An edge gate runs no coverage stage
(SM1083 ruling, coverage for stable only), and the same suite had run twice on
the host at that level of memory in the hour before.

The release manager chose to fix the rule before gating, rather than gate once
with an override.

# What shipped

- `tools/preflight.sh SUITE` is `HEAVY` without the swap rule. Memory under
  the threshold, short stage disk and inodes still refuse. Swap in use is
  printed as a note saying why it does not refuse.
- `tools/gate-main.sh` starts the check in `SUITE` mode unless the coverage
  stage will run: stable, certified, or `LAZYSITE_COVER_FORCE=1`, the same
  rule release.sh uses.

t/tools/156 covers the mode. t/tools/168 drives the real gate-main.sh to its
start check with stale swap and an impossible disk requirement: an edge gate
gets past the swap and stops on the disk; a stable gate, or an edge gate with
coverage forced, stops on the swap.
