---
id: SM949
title: "SM949: A fast pre-check: lints, related tests and changed-line tidy in about a minute"
subtitle: "Most handoff re-runs in 0.15.2 were tidy alignment or a lint, found only after the 6-minute suite."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: testing
status-note: "Filed 2026-10-07 at the release manager's direction, from the development-cost analysis. Size S. Planned in WORK-PLAN-0153 group E."
---

# Measured

Of about 13 handoffs in the 0.15.2 cycle, most re-runs were for tidy alignment on a touched line, a lint, or a generated doc - all knowable in seconds, found after a 6-minute full suite.

# Proposal

`make tier-precheck` (and handoff's first step): all lints, the tests whose files or subjects match the changed files, and tidy on changed lines; under about a minute, failing fast with the one command that fixes each finding.

# Done when

A change that would fail the handoff on a lint, tidy or generated doc fails the pre-check first.
