---
id: SM764
title: "SM764: a branch is handed over gated, a timeout declares what it bounds, and the coverage gate re-runs a failed file alone once"
subtitle: "The 0.13.4 cut was launched three times. Two faults reached review and the build that the whole plain suite on the branch would have caught in two minutes; each cost a review round-trip through a release manager who was not watching. The release manager, 2026-09-07: review the process and alter it so these failures do not occur, ask for reviews up front, and say when it is with you."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-07 on claude/sm764-a-branch-is-handed-over-gated for 0.13.5. tools/handoff.sh + make handoff (tier-review + tripwires, prints READY); t/lint/120 (every alarm is instrumentation-aware or marked network-bound); coverage.sh re-runs a failed file alone once, recorded; DEVELOPER.md rule. The communication half is a standing rule in memory, not code."
---

# What happened, in order

| Launch | Failed at | Cause | Would have been caught by |
| --- | --- | --- | --- |
| 19:38 | coverage stage, 2 h in | `t/unit/plugins/41`: the pandoc plugin's 20 s render ceiling met under Devel::Cover at four jobs; passes alone | a rule that a CPU-bound ceiling widens under instrumentation (SM763); failing that, a single recorded re-run alone |
| 05:12 | plain suite, 12 min in | `t/unit/plugins/40` pins `$TIMEOUT_SECONDS = <digits>` textually; the SM763 expression broke it. I had run only test 41, not its siblings | `make tier-review` on the branch - the tier the ladder already names for handoff |
| 05:33 | - | - | - |

Between each launch: a fix branch, a review by the release manager, a
landing, a relaunch. The release manager was away; the programme slipped by
many hours for two faults worth two minutes each.

# What is built

**The handoff is a gate, not a step.** `tools/handoff.sh` (`make handoff`,
`--release` / `RELEASE=1` for a cut-bound branch): a clean tree, every changed
Perl file compiles, the diff carries no mangled literal, the whole plain suite
at -j4, and bench for a cut-bound branch. It prints one line - `READY FOR
REVIEW: <branch> <sha> (tier-review passed)` - and a branch is not offered
for review without it. DEVELOPER.md's tier ladder carries the row and the
rule.

**A timeout declares what it bounds.** `t/lint/120`: every `alarm` in the
engine is either a variable whose assignment carries the Devel::Cover branch
(CPU- or subprocess-bound work: a render, a `--describe`) or a literal marked
`# network-bound` (a peer this process's instrumentation does not slow: XMPP,
SMTP, a git remote). The three network sites are marked; the two CPU sites
already carried the rule. A third alarm with neither is the next 0.13.4.

**The coverage gate re-runs a failed file alone, once, and says so.** A file
that fails in the parallel instrumented run is run once more alone under the
same instrumentation; if it passes, the stage proceeds and the log, the
coverage-check output and the release log all carry `PASSED ALONE (failed in
the -j4 run): <files>` - a test that passes alone and fails in company is a
fact somebody should read, not a fault to hide. If it fails alone too, the
stage fails as before.

# The other half: when it is with the release manager

Not code. The rule, recorded in memory: **every hand-over names what needs
the release manager's action, in one place, and is followed by a
notification** - a branch ready for review, a build at its terminal state
(tagged or failed), a decision needed. Reviews for one cut are asked for
together where the work allows, so one sitting clears them. "Don't ping me
until it's done" and "tell me when it is with you" are the same rule from two
sides: silence while it is with me, one line when it is with them.

# Not done

`make handoff` runs the plain suite, not the instrumented one; the
instrumented failure mode is covered by the lint and the re-run, not by a
pre-launch instrumented pass (~95 min, which would double the cost of every
handoff for a class of fault the lint now holds).
