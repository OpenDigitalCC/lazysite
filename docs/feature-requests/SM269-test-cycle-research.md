---
title: "SM269 - Test-cycle research: cut the gate's wall-clock without cutting the gate"
subtitle: "A commissioned four-phase research project. The full gate is about an hour, most of it coverage re-running the whole suite under Devel::Cover, and it sits on a human's critical path at every cut."
brand: plain
status: candidate
status-note: "PHASES 0, 1 AND 2 DONE (2026-08-10/11, unreleased on main). Phase 0: the hour attributed - coverage is 92% of gate wall-clock at a 12.4x instrumentation multiplier, the top 20 files are half the plain suite, and 57-65% of the spawn-heavy tests is perl compiling the same five CGIs (measured with strace, not assumed). Phase 1: the two perlcritic sweeps sharded across forks (41.3s->15.5s, 31.7s->12.9s, both verified still failing on a real violation) and the shared repo-root manifest given one owner instead of six copies of its lifecycle, so prove -j4 is green at 122s against 330s. Phase 2: the tier ladder in the Makefile (tier-dev/tier-review/tier-release/tiers) and DEVELOPER.md, with NO scheduled tier - phase 3 has to justify one. NEGATIVE FINDING worth keeping: preload (yath) cannot touch the compile tax, because it is paid in CGI subprocesses the tests spawn themselves and no harness can preload a child it does not control; like-for-like yath is 126s against prove -j4 at 122s. PHASE 3 REMAINS and is the only thing that moves the 80 minutes. ORIGINAL: FILED 2026-08-10 from inbox/test-cycle-research.md, commissioned by the product owner via the toolchain-development session. Research, not a change request: measure first, report honestly, and a strategy that does not pay is a result. Reports go to /srv/projects/toolchain-development/inbox/ per the cross-project convention. Not started."
---

# SM269 - test-cycle research

## Why

The full release gate takes about an hour of wall-clock. The long pole is
`tools/coverage.sh --check`, which re-runs the whole suite under Devel::Cover,
instrumenting every CGI subprocess - so the suite effectively runs twice, once
plain and once slow. That hour sits on a human's critical path at every cut.

The team position is unchanged and this project does not touch it: fewer,
better-tested releases, with the **full gate before every build**. What is in
scope is the wall-clock, *where the waiting happens*, and earlier cheaper tiers
so problems surface while the code is being written rather than at the cut.

Two steers from the product owner set the priorities:

**Tiers and parallelism first.** These are judged the biggest wins. Different
categories of test belong at different lifecycle points, and the plain suite
should parallelise.

**A scheduled run must be progressive.** A nightly that merely re-measures is
waste. A scheduled tier is justified only if every run emits an actionable
improvement worklist - ranked coverage gaps, slowest-test targets, flake
detection, a file-to-tests selection map - and that worklist has a named
consumer. Measurement without a consumer is not a tier; it is heat.

## Research questions

1. Where does the hour actually go - compile time, test logic, or I/O - and how
   is it distributed across test files?
2. How far does parallel execution divide the plain-suite wall-clock, and what
   has to change for the suite to be parallel-safe?
3. What is the right tier ladder for this project, and what does each tier catch
   in practice?
4. Can coverage come off the interactive gate without loss of assurance, by
   making its scheduled replacement progressive?

## Phases

**Phase 0 - measure.** No optimisation until the time is attributed.
`prove --timer` (keeping `--state`), rank the files by elapsed, expect a Pareto
shape, identify the top 20. For a sample of slow files, attribute time between
perl compile/startup per spawned CGI subprocess, test logic, and filesystem or
network I/O - the process-per-request shape makes compile tax the prime suspect,
but measure rather than assume. Time `tools/coverage.sh --check` separately and
record the instrumentation multiplier.

Deliverable: a timing table (top-20 files, attribution, plain vs instrumented).

**Phase 1 - parallelise the plain suite.** Audit for parallel-safety blockers:
fixed ports, shared docroot state (the dev server writes runtime state into the
docroot), shared tmp paths, order-dependent fixtures. Catalogue every collision
class. Give each test its own world - per-test tempdir, ephemeral ports -
starting with phase 0's top 20. Measure `prove -jN` at N = 2, 4, 8 and record
the curve. Evaluate `Test2::Harness` (`yath`) with **preload** as the
alternative: if compile dominates, loading the application once per worker may
beat raw `-j`.

Success criterion: plain suite under 10 minutes on the build host, no test
weakened, failures still attributable to a single file.

**Phase 2 - the tier ladder.** Formalise in DEVELOPER.md with Makefile targets:
dev tier (seconds to ~2 minutes, every edit: lint, the touched `t/unit/<area>/`,
the change's own regression test); review tier (~10 minutes at branch handoff,
which phase 1 may dissolve into "just run it"); release tier (the full gate,
unchanged); scheduled tier (only what phase 3 justifies). The emergency-patch
policy then reads as a declared point on this ladder rather than an exception.

**Phase 3 - progressive measurement.** Test the hypothesis that coverage is a
measurement of the suite rather than a test of the code, drifts slowly, and can
run on a schedule - provided each run emits a ranked worklist with a named
consumer, and the next run states what moved. The gate's coverage step would
become a freshness check (latest scheduled run green, recent, no structural
change since), with a full instrumented run on demand when that cannot be
satisfied. **If the progressive outputs turn out to have no consumer in
practice, that is the finding**, and coverage stays at the gate. Evaluate
`Devel::Cover -select` on the engine's own libs regardless.

## Out of scope

- Test selection as a substitute for any release-tier run. It is a dev-loop
  accelerator only.
- Any reduction in what the release gate checks.
- Changes to the release cadence or the uncommitted-tree release contract.
- Offloading to a separate gate-runner host - a promising follow-on that
  composes with the vcs-review hold/release mechanism, but out of scope until
  this project's numbers say what a runner would actually run.

## Reporting

One report per phase to `/srv/projects/toolchain-development/inbox/`:
measurements before and after, what changed, what did not pay, and any suite
defects found on the way. Parallel-safety work routinely surfaces real bugs;
those go through the normal defect route as their own filings, not buried in a
phase report.

If the tier ladder and the progressive-measurement pattern prove out, they
become candidate corpus material for the software-design-practices framework -
generic, like the emergency-patch and channel-promotion policies, and grounded
in this project's numbers rather than asserted.

## Note on sequencing

This is a whole-project piece of work and it competes with feature and security
delivery for the same hour. Phase 0 is an afternoon and answers whether the rest
is worth doing - it should not be bundled into a release cycle.
