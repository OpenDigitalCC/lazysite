---
id: SM1454
title: "SM1454: a small patch is cheap to release"
subtitle: "A one-line security fix cost over an hour of gate time, most of it a full suite on a tree that differs from a gated one by a line. A patch gates on its diff, a tree is never run twice, the full suite can run on the lab, and the slow tests are trimmed."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-16
raised-by: "the release manager (ruling 258), after the 0.17.1 estimate"
area: release
status-note: "OPEN. R1 (--patch), R2 (the suite pass record) and R4 (confirm-register) built on n834, tools only; R3 (the lab runner) is n835's, R5 is not built. The first patch to use R1 is a full gate if it carries these tools: they are a trigger."
---

# What happened

The 0.17.0 field walk found the bad-URL guard inert behind Apache (SM1455): one line in the auth
wrapper. The release manager judged the patch not viable at its release cost (ruling 258). Measured
on 0.17.0: the gate's full suite is 2096 s wall clock (6007 CPU-s at -j4, nice 19 on the shared
development host); every other gate stage together is under two minutes; the build is 2.5 minutes;
the precheck on a branch is about 133 s. The suite runs again at the gate though the base tree
passed it at its own release gate and the change is one file.

# The requests

R1 - a patch gates on its diff
: `tools/gate-main.sh --patch` (stable point releases) gates a tree that differs from the last
  released tag of its line, whose gate receipt passed. It runs every lint, the bench check and the
  precheck's selection (related tests and the area map of tools/precheck-areas.pl) for the diff
  from that tag. A changed file that the area map does not cover, or a change to the test
  harness, the lints' own libraries or the release tools, makes it the full suite, and the gate
  says why. The receipt names the mode, the base tag and the tests run.

R2 - a tree is never run twice
: The suite stage records a pass keyed by the tree id (not the commit; the release manager lands
  by rebase) and the gate's options. A gate on a tree with a recorded pass says so and skips the
  suite. A failed or stopped suite records nothing; an unreadable record is a refusal, not a pass
  (ruling 206). SM1449 R1.

R3 - the full suite can run on the lab
: A suite runner that takes the tree to an HPS lab VM, runs the full suite there at the VM's
  parallelism, and brings back the TAP and the exit status, which the gate reads as it reads a
  local run. When the lab is not available, the gate runs locally as today and says so. The VM
  is destroyed after the run.

R4 - one branch, one confirmation
: A patch's fix, its security-register entry and the compliance stamp are on one branch; the
  release manager's confirmation of the register entry is recorded when the branch lands, not as
  a separate round.

R5 - the slow tests are trimmed
: The tests over 20 s at -j4 (tools/precheck.sh's SLOW list) and the changelog lints are made
  faster without losing an assertion, measured before and after.

# To settle when built

- R1's selection is the precheck's: a defect it misses is caught by the nightly full suite on main
  and ships in the next patch. Certified releases keep the full suite and coverage.
