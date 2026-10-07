---
id: SM950
title: "SM950: Release gate: parallel suite, run on landing, coverage reused when its inputs are unchanged"
subtitle: "A gate is ~90 minutes and any later commit restarts it; 0.15.2 needed three."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: release
status-note: "SHIPPED (PENDING). (1) the gate suite runs -j4 (n244). (2) tools/gate-main.sh gates main after each landing, a rehearsal until the pre-cut pass. (3) passing coverage runs are kept by inputs digest and reused by a later gate; the digest leaves out tests that reach nothing measured (n272)."
---

# Measured

The gate runs the suite serially (17 min; 6 min with -j4) and coverage for ~70 min. Its receipt is tied to one SHA, so the SBOM declaration and a lint fix after a passing gate each cost a full re-run: three gates and a coverage pre-check for 0.15.2. The host now has the memory for -j4 (release manager, 2026-10-07).

# Proposal

(1) The gate suite runs with -j4. (2) The developer agent runs the gate on main after each landing, so a receipt is usually ready when a cut is called. (3) Coverage is skipped when the coverage-inputs digest matches a recorded pass, as coverage.sh already supports - and the digest is narrowed so a change to a test that exercises no measured code does not move it.

# Done when

A gate on an unchanged-coverage commit takes the suite's time, not 90 minutes; a cut normally starts from an existing receipt.
