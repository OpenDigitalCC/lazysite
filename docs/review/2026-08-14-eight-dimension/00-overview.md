---
title: "Eight-dimension non-functional review - lazysite - aggregated overview"
subtitle: "0.10.8 EDGE (ec6fe0a), 2026-08-14, Commercial regime - eight dimensions in signoff order"
brand: plain
standard-margins: true
---

# What this is

The fourth full eight-dimension non-functional review of lazysite, run against
the framework in `/srv/projects/toolchain-development/TOOLCHAIN.md` - the eight
dimensions in signoff order, with per-dimension refusal conditions keyed to the
declared regime. lazysite declares the **Commercial** regime in
`docs/POLICY.md`.

Predecessors: 2026-06-23 (seven-dimension), 2026-07-01, 2026-07-10, and
2026-07-18 (the 0.8.0 stable gate). Each 2026-07-18 finding was verified as
fixed or open rather than assumed.

**The audited artefact is an EDGE release, not a stable candidate.** That
distinction matters for how the verdicts should be read: this is a periodic
close-out over the 0.8.x, 0.9.x and 0.10.x lines, not a gate on a cut that is
about to happen. Where a dimension refuses, it refuses *a stable promotion* -
except D1/D6, where the defect is live in a build that is deployed.

The audited tree is `main` at `v0.10.8` (`ec6fe0a`), assessed in a clean
worktree. Two branches awaiting `vcs-review` are **not** in the audited tree and
are named where they change a verdict:
`claude/sm296-acl-set-crash` and `claude/sm294-front-door-under-the-pool`.

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
3 | Test coverage | WARN | PASS | The suite does not pass on a clean checkout of the tag: 15 test files need `install.pl`, which needs a gitignored build artefact. Coverage floors themselves are enforced and met
4 | Performance | WARN | PASS | Baseline captured 2026-07-02, predating two minor lines; 2x tolerance against ~3% measured spread; the registries moved onto the request path unbenchmarked
5 | Reliability and resilience | WARN | PASS | The restore-rehearsal cadence the declaration itself mandates has lapsed for four stable releases; `docs/MONITORS.md` still absent
6 | Security | REFUSE | REFUSE (cleared) | The D1 defect's consequence is an exposure; the significant-change register is stale over its own triggers; the threat model of record does not mention the private store or the front door
7 | Documentation | WARN | WARN (cleared) | FEATURES.md's timeline stops at 0.9.14, eight releases back; POLICY.md cites the 2026-07-01 review as current
8 | Policy compliance | REFUSE | WARN | The Declaration of Conformity is unsigned and stamped 0.8.0; three stable releases have shipped since
```

# Overall

**A stable promotion refuses today**, on D1, D6 and D8. One of those is a code
defect with a fix already written; the other two are paperwork.

That summary is accurate and, on its own, misleading. It should be read
alongside the engineering the period actually contains, because the two are
almost opposites.

# The finding behind the findings

Sort this review's results by whether the thing assessed is **defended by a
mechanism** or **maintained by a person**, and the table reorganises itself
completely:

```datatable
columns: Defended by a mechanism | State | Maintained by hand | State
widths: X | 1.6cm | X | 1.6cm
bold: 1
tone: light
---
perlcritic + tidy gates | clean | Declaration of Conformity | 3 releases stale
Coverage floors (`coverage-floor`) | enforced, met | Significant-change register | stale over its own triggers
Strict SBOM gate | right mechanism, unrunnable from the tag | FEATURES.md timeline | 8 releases stale
`t/lint/36` access model vs code | pinned | STRIDE/ASVS threat model | predates the architecture
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
correctly converted the list into something derived. The same failure is running
unchecked through the compliance and documentation records, where nobody has yet
made that move.

The recommendation follows directly and is the single most valuable thing in
this review: **treat the release records as code, and gate them.** Concretely -
a release-gate check that refuses a stable cut when the DoC version is behind
the tag; when the significant-change register has no entry covering the SM
numbers in the release; when FEATURES.md's newest timeline entry is older than
the tag; when the newest rehearsal predates the last stable; when the bench
baseline predates the tag. Each is a few lines against data the project already
has, and each replaces a person remembering with a build failing. The project
has proven it knows how to do this - it has done it four times this month, just
not to these files.

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

1. **Land the SM296 fix** (D1 F1.1 / D6 F6.1). Written and tested on
   `claude/sm296-acl-set-crash`; awaiting review. Until it ships, the re-apply
   sweep that the 0.10.8 changelog tells operators to run is the operation that
   crashes.
2. **Finalise and sign a Declaration of Conformity** for the current stable
   (D8 F8.1), and add advancing it to the stable-cut procedure.
3. **Write the significant-change register entries** for SM286 (new processing
   of restricted data) and SM293 step 5 (new external interface) (D6 F6.2). The
   pentest waiver's validity depends on this register being kept.
4. **Update the threat model of record** to describe the private store and the
   front door (D6 F6.3).
5. **Run and record one restore rehearsal** against the current stable, then
   hold or amend the declared cadence (D5 F5.1).

# Recommended, not blocking

6. Make the tag self-sufficient (D3 F3.1, D6 F6.6). `release-manifest.json` is a
   gitignored build artefact, and **two** things need it: `install.pl` - so
   fifteen test files fail on a clean checkout - and the strict SBOM gate, which
   is a CRA control. A released tag currently fails its own tests and cannot run
   its own compliance check for anyone who clones it. One fix closes both.
7. Re-capture the bench baseline at each stable cut, add a registry-generation
   op, and add a warn-level tolerance band (D4 F4.1, F4.2). The run on this tree
   passed while sitting 7.5-27.5% above baseline on every op.
8. Retire the three branch-floor overrides in `dist/config/coverage-floor` -
   they now measure 64.6-65.6% against a 62% general floor, which is the
   retirement condition the file states for itself (D3 F3.2).
9. Sweep FEATURES.md to the current release and fix POLICY.md's review pointer
   (D7 F7.1, F7.2).
10. Confirm SM283's proxy template is deployed fleet-wide (D6 F6.4, tasks #204
    and #196) - it is absent on `edge.explore.lazysite.io`, the host the
    disclosure came through.
11. Book the third-party pentest engagement: ADR 0007's waiver expires
    2026-12-31 or at first GA marketing, whichever comes first (D8 F8.3).

# Reports

- `dimension-1-correctness.md`
- `dimension-2-code-quality.md`
- `dimension-3-test-coverage.md`
- `dimension-4-performance.md`
- `dimension-5-reliability.md`
- `dimension-6-security.md`
- `dimension-7-documentation.md`
- `dimension-8-policy.md`
