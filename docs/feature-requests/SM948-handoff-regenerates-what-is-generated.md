---
id: SM948
title: "SM948: Handoff regenerates the generated docs instead of failing on them"
subtitle: "The capability map, actions reference, host-deps doc and doc index fail the handoff when stale; each costs a re-run."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: testing
status-note: "Filed 2026-10-07 at the release manager's direction, from the development-cost analysis. Size S. Planned in WORK-PLAN-0153 group E."
---

# Measured

Four documents are generated from code and checked by tests (t/tools/26, t/tools/25, lint 110). In 0.15.2 a stale one failed the 6-minute handoff three times, each fixed by running one command and handing off again.

# Proposal

`tools/handoff.sh` runs the generators first and commits any change as its own commit with a fixed message, then runs the suite. A generator that fails still fails the handoff.

# Done when

No handoff fails on a stale generated document.
