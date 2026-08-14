---
title: "Eight-dimension non-functional review - lazysite - aggregated overview"
subtitle: "0.10.8 EDGE (ec6fe0a), 2026-08-14, Commercial regime - eight dimensions in signoff order"
brand: plain
standard-margins: true
---

# Current state, in one line

**lazysite 0.10.8 passes one dimension of eight, warns on four, and refuses on
three.** A stable promotion refuses today. The engineering in this period is the
strongest in the project's history; almost every refusal is a *record* that
stopped tracking it.

```barchart
caption: Dimension verdicts at 0.10.8 (eight dimensions, signoff order)
axis: H
style: full
---
PASS: 1
WARN: 4
REFUSE: 3
```

Of the three refusals, **one is code** - a live defect with a written fix
awaiting review - and **two are paperwork**: an unsigned declaration and an
absent reporting obligation. Of the four warnings, three are records that have
fallen behind a fast release cadence and one is a test-reproducibility problem.

```datatable
columns: Reading this report | Where
widths: X | 6cm
bold: 1
tone: light
---
What is broken and what it costs | "Verdicts" below, then the dimension report named in each row
Why so much went stale at once | "The finding behind the findings"
What must happen before a stable cut | "Required before a stable promotion"
What keeps it from happening again | "Maintaining compliance", split build / operate
What the next release actually buys | "What the next release changes"
```

# What this is

The fourth full eight-dimension non-functional review of lazysite, run against
the framework in `/srv/projects/toolchain-development/TOOLCHAIN.md` - the eight
dimensions in signoff order, with per-dimension refusal conditions keyed to the
declared regime. lazysite declares the **Commercial** regime in
`docs/POLICY.md`.

Predecessors: 2026-06-23 (seven-dimension), 2026-07-01, 2026-07-10, and
2026-07-18 (the 0.8.0 stable gate). Each 2026-07-18 finding was verified as
fixed or open rather than assumed.

**Every verdict in this report belongs to a version.** The audited tree is
`main` at `v0.10.8` (`ec6fe0a`), assessed in a clean worktree. A prior column
records what the earlier review said *about the version it assessed*; where a
finding was resolved after that review, it is resolved in a later version and
the fact belongs to that version's record, not to this one's prior column.

The audited artefact is an **EDGE** release, not a stable candidate. This is a
periodic close-out over the 0.8.x, 0.9.x and 0.10.x lines rather than a gate on
an imminent cut. Where a dimension refuses it refuses *a stable promotion* -
except D1/D6, where the defect is live in a build that is deployed.

Two branches awaiting `vcs-review` are **not** in the audited tree and are named
where they change a verdict: `claude/sm296-acl-set-crash` and
`claude/sm294-front-door-under-the-pool`.

# Verdicts

```datatable
columns: # | Dimension | Assessed | Prior | Why
widths: 0.8cm | 3.4cm | 1.5cm | 1.3cm | X
bold: 3
tone: medium
text: 5
---
1 | Correctness and groundedness | REFUSE | PASS | A croaking `make_path` makes the guard after it unreachable; a protect call dies leaving content stored-as-protected and still served. Live in 0.10.8. Fix written, on a branch
2 | Code quality | PASS | PASS | perlcritic sev-3 clean tree-wide; lint suite 12 -> 41 and improved in kind. Render path up 52% since 0.7.0 - recorded as pressure, not charged
3 | Test coverage | WARN | PASS | The suite does not pass on a clean checkout of the tag: 15 test files and the SBOM gate need `install.pl`, which needs a gitignored build artefact. Coverage floors themselves are enforced and met
4 | Performance | WARN | PASS | Baseline captured 2026-07-02, predating two minor lines; the gate passed while every op sat 7.5-27.5% above it; the registries moved onto the request path unbenchmarked
5 | Reliability and resilience | WARN | PASS | The restore-rehearsal cadence the declaration itself mandates has lapsed for four stable releases
6 | Security | REFUSE | REFUSE | The D1 defect's consequence is an exposure. The register and threat-model findings raised here have been remedied on this branch; the refusal now rests on the live defect alone
7 | Documentation | WARN | WARN | FEATURES.md's timeline stops at 0.9.14, eight releases back; POLICY.md cites the 2026-07-01 review as current
8 | Policy compliance | REFUSE | WARN | The Declaration of Conformity is unsigned and stamped 0.8.0 with three stable releases shipped since; and CRA Article 14 reporting had no owner, no runbook and no mention in the tree
```

# The finding behind the findings

Sort this review's results by whether the thing assessed is **defended by a
mechanism** or **maintained by a person**, and the table reorganises itself
completely:

```datatable
columns: Defended by a mechanism | State | Maintained by hand | State
widths: X | 1.8cm | X | 1.8cm
bold: 1
tone: light
---
perlcritic + tidy gates | clean | Declaration of Conformity | 3 releases stale
Coverage floors (`coverage-floor`) | enforced, met | Significant-change register | stale over its own triggers
Strict SBOM gate | right mechanism, unrunnable from the tag | FEATURES.md timeline | 8 releases stale
`t/lint/36` access model vs code | pinned | STRIDE/ASVS threat model | predated the architecture
`t/lint/35`/`37` two-copy parity | pinned | Restore-rehearsal register | 4 stable cycles lapsed
Generated capability map | current | Bench baseline | 6 weeks, 2 minor lines stale
`t/lint/31`/`41` derived lists | pinned | POLICY.md review pointer | 2 generations stale
```

Every column-one item passes. Every column-two item is a finding. Not one
mechanised control has rotted; not one hand-maintained record has survived six
weeks of a fast release cadence.

This is not a new lesson for this project - it is *the* lesson this project has
been teaching itself all period. It found a hand-maintained list silently going
stale **four separate times** in the code (t/lint/31's templates, t/lint/39's
scripts, t/lint/41's deb payload, t/lint/34's config list), and each time
correctly converted the list into something derived. The same failure was
running unchecked through the compliance and documentation records, where that
move had not been made.

**It has now been made.** `tools/lazysite-compliance.pl` runs in the release
gate and refuses a cut when a compliance record is behind the version being cut,
with blocking conditions that differ by channel. On the audited tree it reports
three blocking findings for a stable cut - the same three this review found by
hand.

# What this period got right

Recorded deliberately, because a review that lists only defects misrepresents
the work.

- **The structural fix was taken rather than patched.** SM248, SM268 H17 and
  SM283 were one cause: security living in front-end configuration the project
  ships as a template, cannot test where it is installed, and mostly cannot see.
  Every previous response had been "put the rule in one more config file". The
  0.10.8 line took the other answer and moved the decisions inside the engine.
- **The defect class was named and hunted.** "A control reports success without
  doing the work" was identified as a recurring shape and five instances were
  closed - including one in the project's own security probe, which had shipped
  passing by testing nothing.
- **Tests are shown failing first.** Spot-checked repeatedly; `t/lint/33` was
  verified failing both with the templates absent and with the ACL branch
  stripped while the observable header stayed.
- **Explanations get falsified.** Running nginx for real disproved a claim the
  project had made in three places about *why* a protection worked. The
  protection was real; the reason was wrong; no text match would ever have
  caught it.
- **Deferred work is filed, not implied.** SM294 shipped items 1, 3 and 4 of its
  own plan and filed item 2 as SM297 with the argument for not taking it - an
  auth-spine rewrite where being wrong is an authentication bypass.

# Required before a stable promotion

These are **build-side**: the development team discharges them in the
repository, and a release carries them.

1. **Land the SM296 fix, then re-apply the affected rules** (D1 F1.1 / D6 F6.1).
   This is two things, and the second is easy to miss:
    - the fix is **not in 0.10.8** - it is on `claude/sm296-acl-set-crash`, so
      deploying 0.10.8 does not close it. It needs a release (0.10.9 or later),
      built and deployed;
    - **and then an operator re-apply sweep**, because content protected while
      the bug was live is stored-as-protected and still served, and nothing
      re-runs the move automatically. Deploying the fix stops new breakage; it
      does not repair sites already in that state.
2. **Finalise and sign a Declaration of Conformity** for the current stable
   (D8 F8.1). Now enforced: `lazysite-compliance.pl` blocks a stable cut on a
   declaration behind the version or unsigned.
3. ~~Write the significant-change register entries~~ - **done for this version**
   (D6 F6.2). `docs/SECURITY.md` carries the SM286/SM293 entry, assessed as
   accepted-with-a-condition, the condition being SM296.
4. ~~Update the threat model of record~~ - **done for this version** (D6 F6.3).
   `docs/architecture/security.md` gains "Content outside the served tree" and
   "The front door"; `docs/SECURITY.md` gains two trust boundaries and revised
   STRIDE rows.
5. **Run and record one restore rehearsal** against the current stable (D5
   F5.1). Now enforced: the gate blocks a stable cut when the newest rehearsal
   predates the last stable cut.

# Maintaining compliance

Split by **who does it and on what clock**, because these are different teams
with different lifecycles: a build obligation is discharged by cutting a
release; an operate obligation is discharged by a person acting on a running
service, on a calendar that has nothing to do with the release cadence.

## Build side - the project, in the repository

Largely addressed in this cut, and recorded here so the state is legible:

```datatable
columns: Item | State | Where
widths: 5.4cm | 2.2cm | X
bold: 1
tone: medium
text: 3
---
One dated obligations register, anchored on dates AND versions | DONE | docs/compliance/OBLIGATIONS.md - reviewed at every release, `reviewed_at_version` gated
Annex VII technical file, started as an index | DONE | docs/compliance/TECHNICAL-FILE.md - assembly over artefacts that already exist, `covers_version` gated
Release compliance hook | DONE | tools/lazysite-compliance.pl, wired into tools/release.sh ahead of the slow gates; t/tools/39 proves it blocks
Support period written absolutely | DONE | 2031-07-10 in the obligations register, not "five years from 0.7.0"
Signed releases (Sigstore/cosign) | OPEN | Cannot be applied retroactively - every unsigned release is permanently unattestable, the only debt here that can never be paid down
Vulnerability register evidencing the ADR 0007 SLAs | OPEN | Declared SLAs with no record are assertions; the register format is in the maintenance template
```

## Operate side - whoever runs an instance

The project cannot discharge these and should stop writing them as though it
could. What it can do is **ship the templates that say so**, which it now does:
`docs/compliance/OPERATIONS-TEMPLATE.md` (what the deployment is - identity,
named people, reporting path, SLOs) and
`docs/compliance/COMPLIANCE-MAINTENANCE-TEMPLATE.md` (the recurring schedule and
its three registers). Both are packaged in `lazysite-common`, enforced by
`t/lint/41`. The operator fills in the front matter, validates that each
statement is true of the running service, and signs.

The two were separated deliberately. The declaration changes rarely and is
signed once; the schedule is never finished and is the thing that decays
silently. **Every compliance failure this review found in the project's own
records was a maintenance failure, not a declaration failure** - the
declarations were written and correct, and the recurring work stopped.

Carried as operate-side state rather than as instructions in a development
review:

```datatable
columns: Item | Date | Recorded as
widths: 5.4cm | 2.6cm | X
bold: 1
tone: medium
text: 3
---
CRA Article 14 reporting path rehearsed, with a named triage owner and deputy | 2026-09-11 | A section of the operations declaration with a signature against it, plus a rehearsal row in the maintenance register. The framework's OPERATIONS-GUIDE #report-path-rehearsal is the source; it names the same date
First third-party penetration test | 2026-12-31, or first GA marketing | A row in the operations declaration's posture, and an obligations-register row. Stated as a position the operator holds and reviews - not as a task in a dev backlog, where it has sat un-actioned across three reviews
Restore rehearsal, per upgrade and at least annually | continuous | Rehearsal register in the maintenance template
Vulnerability intake, triage and notification decisions | continuous | Vulnerability register in the maintenance template; the "Notified?" column IS the Article 14 decision, recorded at the time
Deployment record | per deployment | Deployment register in the maintenance template
```

# What the next release changes

A stated dev outcome is **a passing report**. This is what the next release can
and cannot reach, so the gap is explicit rather than discovered at the next
review.

```datatable
columns: # | Dimension | Now | Next release | What has to happen
widths: 0.8cm | 3.2cm | 1.4cm | 1.6cm | X
bold: 2
tone: medium
text: 5
---
1 | Correctness | REFUSE | PASS | Land SM296. Build-side, already written
2 | Code quality | PASS | PASS | Nothing
3 | Test coverage | WARN | PASS | Make the tag self-sufficient - generate `release-manifest.json` when absent, which fixes the suite and the SBOM gate together
4 | Performance | WARN | PASS | Re-capture the baseline at the cut, add a registry-generation op, add a warn band
5 | Reliability | WARN | PASS | Run one restore rehearsal and record it. Half an hour
6 | Security | REFUSE | PASS | Land SM296; the register and threat model are already done
7 | Documentation | WARN | PASS | Sweep FEATURES.md to the release, fix POLICY.md's review pointer
8 | Policy compliance | REFUSE | WARN | Signing the Declaration is a HUMAN act - dev cannot do it. Article 14 readiness is operate-side and dated 2026-09-11
```

**Six of eight can reach PASS on build-side work alone, and the seventh
(reliability) needs half an hour of someone's time.** D8 cannot: it requires a
signature from the responsible person and a named security triage owner with a
rehearsed reporting path. Those are not gaps in the code and no amount of
development closes them.

So the honest target for the next release is **7 PASS / 1 WARN**, and a fully
passing report is reachable at the stable cut after the Declaration is signed
and the reporting path is rehearsed. Both have dates; both are now in
`docs/compliance/OBLIGATIONS.md`; and the release gate now refuses a stable cut
that pretends otherwise.

# Recommended, not blocking

- Make the tag self-sufficient (D3 F3.1, D6 F6.6). `release-manifest.json` is a
  gitignored build artefact and **two** things need it: `install.pl` - so
  fifteen test files fail on a clean checkout - and the strict SBOM gate, which
  is a CRA control. One fix closes both.
- Re-capture the bench baseline at each stable cut, add a registry-generation op,
  and add a warn-level tolerance band (D4). The run on this tree passed while
  sitting 7.5-27.5% above baseline on every op.
- Retire the three branch-floor overrides in `dist/config/coverage-floor` - they
  now measure 64.6-65.6% against a 62% general floor, which is the retirement
  condition the file states for itself (D3 F3.2).
- Sweep FEATURES.md to the current release and fix POLICY.md's review pointer
  (D7 F7.1, F7.2).
- Confirm SM283's proxy template is deployed fleet-wide (D6 F6.4, tasks #204 and
  #196) - it is absent on `edge.explore.lazysite.io`, the host the disclosure
  came through.

# Reports

- `dimension-1-correctness.md`
- `dimension-2-code-quality.md`
- `dimension-3-test-coverage.md`
- `dimension-4-performance.md`
- `dimension-5-reliability.md`
- `dimension-6-security.md`
- `dimension-7-documentation.md`
- `dimension-8-policy.md`
