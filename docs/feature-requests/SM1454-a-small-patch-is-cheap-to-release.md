---
id: SM1454
title: "SM1454: a small patch is cheap to release"
subtitle: "A one-line security fix cost over an hour of gate time, most of it a full suite on a tree that differs from a gated one by a line. A patch gates on its diff, a tree is never run twice, the full suite can run on the lab, and the slow tests are trimmed."
brand: plain
standard-margins: true
status: partial
raised: 2026-11-16
raised-by: "the release manager (ruling 258), after the 0.17.1 estimate"
area: release
status-note: "PARTIALLY SHIPPED (0.17.1): R1 (--patch, tools/patch-plan.pl), R2 (the suite pass record), R4 (confirm-register) and R5 (the slow tests trimmed, 449 s to 123 s). R3, the lab runner, is built on n840 and R6 (the patch compliance stamp, the filing status, the record checks before the suite) on n845, R7 (edge and beta patches stamped too) on n850, all for 0.17.x. Status stays partial."
---

# What happened

The 0.17.0 field walk found the bad-URL guard inert behind Apache (SM1455): one line in the auth
wrapper. The release manager judged the patch not viable at its release cost (ruling 258). Measured
on 0.17.0: the gate's full suite is 2096 s wall clock (6007 CPU-s at -j4, nice 19 on the shared
development host); every other gate stage together is under two minutes; the build is 2.5 minutes;
the precheck on a branch is about 133 s. The suite runs again at the gate though the base tree
passed it at its own release gate and the change is one file.

Measured on 0.17.1, the first patch released with R1, R2, R4 and R5: three gates and two
extra branches between the first gate and the build, about 2h40. The first gate stopped in 10 s
at the compliance check (the obligations register and the technical file still said 0.17.0),
which needed a walk on its own branch (SM1456). The second ran the full suite for 33 min and
failed on one lint (t/lint/26: three filings still `candidate` once the release material
stamped their CHANGELOG bullets), which needed a third branch. The third passed in 31 min. Each
round was a landing and a full suite, because the patch shipped its own release tools (R1's
trigger) and each fix changed the tree (R2's key).

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

R6 - a patch's records are written by the release, not by a branch
: The two steps that cost 0.17.1 two rounds are done by tools/release-material.pl in the gate's
  stage and in the build's release commit, so they are never a branch of their own and never a
  failed gate.
  (a) A stable patch's compliance stamp: when the target is a patch of the line's last stable
  release and the obligations register and the technical file were walked for that release, the
  material stamps reviewed_at_version and covers_version to the target and prepends a dated
  patch-walk clause naming the diff's runtime files and the register entries it carries. A
  runtime change with no register entry, or a minor or certified cut, still needs the walk by
  hand, and the check says so before the suite starts.
  (b) Filing status: a filing whose CHANGELOG bullet the material stamps with a landed SHA and
  whose status is `candidate` is set to `shipped`, its status-note opened with "SHIPPED (X.Y.Z)",
  as it already stamps status-notes of filings marked shipped. A bullet marked as one part of a
  filing (`SM1454 (R3)`) sets `partial` instead.
  (c) Every check that can fail on the release material runs before the suite: the compliance
  check and the lints that read the CHANGELOG and the filings run on the stage first, so a record
  fault fails a gate in seconds, not after the suite.
  (d) The confirmation of a drafted register entry is a branch, not a commit on main: an agent
  cannot commit on main. `confirm-register` cuts `claude/confirm-SMNNNN` from main in a worktree
  under tmp/, commits the one file, holds it for vcs-review and prints the branch; the developer
  agent runs it on the release manager's ruling.
  (e) A drafted entry carries its marker: t/lint/594 holds every `(PENDING)` register entry the
  developer agent drafted, from 2026-11-16, to "awaiting the release manager's confirmation" (or
  the confirmed wording) in its Assessment and its verdict, the words `confirm-register` reads.

R7 - an edge or beta patch's records are written by the release too (ruling 262)
: R6 (a) stamped only a stable patch; an edge or beta cut said "walk them by hand", and the 0.17.2
  edge gate stopped at the compliance check (records at 0.17.1, cutting 0.17.2). Every 0.16 edge
  and beta cut had been walked by hand, the same mechanical walk. The material now stamps a patch
  (X.Y.Z, Z above 0) on the stable, edge and beta channels alike, from the line's newest earlier
  release tag whatever its channel; the clause says the channel truthfully ("an **edge patch** of
  0.17.1"). The refusals are R6's: a runtime change with no register entry naming an SM in the
  diff, and records not walked at the base. A new minor (X.Y.0) and a certified cut stay hand-walked.

# To settle when built

- R1's selection is the precheck's: a defect it misses is caught by the nightly full suite on main
  and ships in the next patch. Certified releases keep the full suite and coverage.
