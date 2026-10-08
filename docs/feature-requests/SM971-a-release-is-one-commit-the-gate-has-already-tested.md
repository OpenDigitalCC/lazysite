---
id: SM971
title: "SM971: A release is one commit on main, and its gate has already run"
subtitle: "One generator writes the release material, the gate tests it, the build commits and tags it, publish pushes main and the tag together - and nobody waits for a test."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-08
raised-by: release manager, 2026-10-08
area: release
status-note: "SHIPPED (PENDING) on n276: tools/release-material.pl writes a release's mechanical material; the gate tests it in its stage (no rehearsal); build makes one release commit on main, checks it, tags it; publish pushes main and the tag atomically; handoff --stack runs one suite per stack. WORK-PLAN-0153 Q12c."
---

# What the release manager asked for

"My decision is required for any git commands, but I am never waiting for
tests. Pre-test just what is done, then full suite, then release at end of full
suite, stamping the release material. Find best route; make changes to the
process if required rather than maintaining tech debt; optimise for efficiency
and token cost, without compromising quality of testing." And: "publish can
push main and tag together."

# What it replaced

A release needed three landings: the feature batch, a **pre-cut** branch
(section retitled, FEATURES entry, briefing re-imported, index regenerated) and
a **post-release record** branch (VERSION/NEXT_VERSION, PENDING refs, GATE-LOG
row, coverage record, the archive at a new minor). Main could not pass a real
gate until the pre-cut had landed - lint 89 reads the briefing's version stamp -
so gate-main.sh rehearsed (`release.sh gate --rehearse`, a receipt build
refused), and the release manager waited out the real gate after the pre-cut.

# What it is now

    land -> (auto) gate -> "cut X" -> build -> publish

- **tools/release-material.pl** writes, into a clean checkout: the CHANGELOG
  section in the house heading (placeholder subtitle without notes), every
  PENDING ref replaced by the landed SHA, the FEATURES entry and subtitle, the
  version pair (by bump-version.pl), the briefing (import-field-practice.pl),
  the index (gen-doc-index.pl), and at X.Y.0 the earlier minors moved to the
  archive. A PENDING ref is the one commit since the newest reachable tag whose
  diff added that exact line; none, several, or the line twice is a refusal
  naming the entry. `--paths` is the release-material allowlist, `--lints` the
  checks that read it (lint 214 keeps that list complete).
- **The gate** runs the generator in its stage and gates that tree, so any commit
  on main can pass. `--rehearse`, `result=rehearsal`, `build --run-gate` and
  `--no-fetch` are removed. The receipt records the generator's digest.
- **The build** needs a passing receipt for main's tip (or a main moved only in
  release material), makes one release commit in a worktree of main - the
  material, the GATE-LOG row, the coverage record - refuses one that touches
  anything else or fails the checks reading it, packages it, tags it locally
  and moves main to it; a stable cut adds a download/ commit. Any failure leaves
  main and the tags as they were.
- **Publish** pushes main and the tag with `git push --atomic`, refusing a tag
  not on local main, an origin main that local main does not contain, and a tag
  already on origin.
- **handoff.sh --stack BASE** prechecks every branch of a stack against the one
  below it and runs the full suite once, on the tip.

The practice briefing now names its sources relative to the repository: run in
a stage, the import printed the stage's own path into a page every site serves.

# Coverage at -j4: measured, and not the same

coverage.sh already ran the instrumented suite at -j4 (SM280, totals measured on
t/unit/mcp). Measured per file on t/unit/lib + t/unit/forms, two runs each:
serial 234 s / 239 s, -j4 78 s / 79 s, -j8 59 s. 148 per-file rows and the total
agreed except lib/Lazysite/Util.pm, identically on every run: 83.3% statements
serial, 83.0% at -j4 and -j8. At -j the counts land on `env_allowlist()`, which
nothing in that subset calls, and leave `_json_str()`, which it does - a
Devel::Cover merge attribution fault, not noise. The gated CGIs the subset
reaches agreed. Nothing was switched; whether to accept -j's attribution or pay
about three times the coverage time serially is the release manager's call.

# Found and not changed

- Filing status-notes still read `SHIPPED (PENDING)` after a release; nothing
  lints them and the generator does not stamp them.
