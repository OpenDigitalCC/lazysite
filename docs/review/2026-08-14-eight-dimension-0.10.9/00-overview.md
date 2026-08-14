---
title: "Eight-dimension non-functional review - lazysite 0.10.9 - aggregated overview"
subtitle: "0.10.9 EDGE (f8bee33), 2026-08-14, Commercial regime - the follow-up review that tests the previous one's projection"
brand: plain
standard-margins: true
---

# Current state, in one line

**lazysite 0.10.9 passes three dimensions of eight, warns on four, and refuses
on one.** The three refusals of six hours ago are down to one, and every code
defect the previous review found is fixed and verified - two of them measured on
the deployed site rather than in the tree.

```barchart
caption: Dimension verdicts at 0.10.9, against 0.10.8 six hours earlier
axis: H
style: full
---
PASS: 3
WARN: 4
REFUSE: 1
```

```datatable
columns: Movement since 0.10.8 | Count | Which
widths: 5cm | 1.6cm | X
bold: 1
tone: medium
text: 3
---
Improved | 3 | D1 REFUSE to PASS, D3 WARN to PASS, D6 REFUSE to WARN
Unchanged | 5 | D2 PASS; D4, D5, D7 WARN; D8 REFUSE
Regressed | 0 | -
```

# The projection, and how it did

The 2026-08-14 review closed by projecting **7 PASS / 1 WARN** for this release.
The actual result is **3 PASS / 4 WARN / 1 REFUSE**. That gap is the most
useful finding in this report, so it is stated before anything else.

```datatable
columns: # | Dimension | Projected | Actual | Why the projection missed
widths: 0.7cm | 2.8cm | 1.3cm | 1.3cm | X
bold: 2
tone: medium
text: 5
---
1 | Correctness | PASS | PASS | -
2 | Code quality | PASS | PASS | -
3 | Test coverage | PASS | PASS | -
4 | Performance | PASS | WARN | The baseline was not re-captured and no registry op was added. Build-side work, identified and not done
5 | Reliability | PASS | WARN | No restore rehearsal was run. Half an hour of a person's time, and nobody's half hour was allocated
6 | Security | PASS | WARN | Three of four findings closed; SM283's proxy template is still absent on the deployed host, which the projection did not account for
7 | Documentation | PASS | WARN | FEATURES.md was swept; POLICY.md's stale review pointer was not. The projection named both and only one was done
8 | Policy compliance | WARN | REFUSE | Correctly identified as needing a signature; the projection then rounded it to WARN anyway
```

::: widebox
**The projection counted work as done because it had been identified.** Four of
the five misses were build-side and within the development team's power -
re-capture a baseline, add a benchmark op, fix a documentation pointer, and (for
D8) advance a declaration. Naming a remedy in a review is not the same as
scheduling it, and a forecast that assumes otherwise will be wrong in the
optimistic direction every time.

This is the same defect class the previous review was written about, applied to
its own closing section: a record that asserts a state nobody mechanised.
:::

The honest reading of the previous review's projection is therefore: it was a
list of what *could* move, presented as what *would*. A future projection should
name the owner and the trigger for each item, or say "unscheduled".

# What this is

The fifth full eight-dimension non-functional review of lazysite, and the first
run against a release cut **since** the review that prompted its contents. Run
against the framework in `/srv/projects/toolchain-development/TOOLCHAIN.md`,
Commercial regime per `docs/POLICY.md`.

Audited artefact: **tag `v0.10.9` at `f8bee33`**, assessed in a clean worktree
of the tag rather than in a working copy - the method note the previous review
recorded, and the one that found its D3 defect.

**Live behaviour was measured on the deployed host.** This is the first review
in the series able to do that: `edge.explore.lazysite.io` was upgraded to 0.10.9
during the review, confirmed cache-independently by a 404 response served
`no-cache, must-revalidate` reporting `lazysite 0.10.9`. Where a finding was
verified against the running service rather than the source, it says so.

# Verdicts

```datatable
columns: # | Dimension | Assessed | Prior | Why
widths: 0.7cm | 2.9cm | 1.4cm | 1.2cm | X
bold: 3
tone: medium
text: 5
---
1 | Correctness and groundedness | PASS | REFUSE | SM296 fixed - `_mkpath` returns rather than croaks. Suite green on a CLEAN checkout: 365 files, 7400 tests
2 | Code quality | PASS | PASS | perlcritic sev-3 clean across every surface, lib and tools; lint suite 41 to 45
3 | Test coverage | PASS | WARN | The suite now passes on a clean checkout of the tag - the release-manifest artefact is derived when absent, closing F3.1 and F6.6 together
4 | Performance | WARN | WARN | Baseline still captured 2026-07-02; no registry-generation op; the 2x tolerance cannot distinguish drift from host load, and this run demonstrates it
5 | Reliability and resilience | WARN | WARN | Newest restore rehearsal is still 2026-07-12, older than the last stable cut. The gate now blocks a stable promotion on it
6 | Security | WARN | REFUSE | The live defect, the stale register and the outdated threat model are all closed. SM283's proxy template remains absent on the deployed host - measured, not assumed
7 | Documentation | WARN | WARN | FEATURES.md swept to 0.10.9; POLICY.md still cites the 2026-07-01 review; ADR 0001 still describes an arrangement it no longer has
8 | Policy compliance | REFUSE | REFUSE | Declaration of Conformity still stamped 0.8.0 and unsigned across four stable releases; CRA Article 14 has no named owner, 28 days out
```

# What actually changed, and how it was verified

Recorded because "the fix shipped" and "the fix works where it runs" are
different claims, and this release could finally test the second.

```datatable
columns: Finding | Verified how
widths: 5.4cm | X
bold: 1
tone: light
text: 2
---
SM296 - protect crashed, content stayed served | Source: `_mkpath` captures the error and returns; `make_path` no longer imported. Regression test blocks the store with a file where its directory must be
SM299 - llms.txt opened with a dead link | LIVE on the deployed host: dead `/.md` links 3 to 0, and the page the filing itself cited now resolves as `/docs/integrations/index.md`
llms.txt defaults | LIVE: 28 entries to 6, bundled docs 26 to 2 - and the 2 survivors are a defect in the change itself (see D7 F7.4)
Clean-checkout suite and SBOM gate | Both run from a fresh worktree of the tag: 365 files 7400 tests PASS, `manifest-to-sbom --strict` rc 0
Significant-change register | Carries a 0.10.9 entry assessing SM294's forked relay; the release gate now checks the register references the version being cut
Threat model | `architecture/security.md` gains the private store and the front door; `SECURITY.md` gains two trust boundaries and revised STRIDE rows
```

# The release gate found a defect in itself

Worth its own heading because it changes what "the 0.10.8 gate passed" is worth.

The gate ran the suite as `prove -r "$STAGE/t/"`, with no `-l`. `PERL5LIB` was
therefore never set, so a test's own in-process library setup covered the test
and not the subprocesses it spawned - and five files drive command-line tools or
a dev server as children. Those children searched only the system module path
and died.

The five files fail **identically at v0.10.8**. So the gate had been running the
suite in a configuration the suite does not support, across at least one release
cut on its authority.

::: textbox
**The naive repair would have been worse than the defect.** `-l` resolves
`./lib` relative to the working directory, and the gate ran from the invoking
directory rather than the staging clone. Adding the flag there would have put
the developer's library on the module path while running the release
candidate's tests - and that version passes. Fixed as
`cd "$STAGE" && prove -lr t/`; both halves are load-bearing.
:::

# Required before a stable promotion

`lazysite-compliance.pl --check --channel stable` answers this directly and
blocks on three:

1. **Sign a Declaration of Conformity** for the current stable. Still stamped
   0.8.0 and unsigned while 0.9.4, 0.9.10 and 0.10.0 stable have shipped.
2. **Run and record a restore rehearsal.** Newest is 2026-07-12, older than the
   last stable cut of 2026-07-27.
3. **Name a security triage owner and deputy, and rehearse the reporting path**
   before 2026-09-11 - 28 days from this review.

None is closeable by development work. All three are tracked as not-done in the
task register rather than assumed.

# Recommended, and this time with an owner

The previous review's recommendations went unscheduled, which is the finding
above. These name what has to happen rather than what would be nice.

```datatable
columns: Item | Dimension | Whose
widths: X | 1.6cm | 3cm
bold: 1
tone: medium
text: 1
---
Re-capture the bench baseline at the next cut and add a registry-generation op | D4 | build, next release
Fix POLICY.md's review pointer and rewrite ADR 0001's "one recorded copy" | D7 | build, next release
Extend the llms.txt defaults change to `starter/docs/*/` - it missed a subdirectory | D7 | build, next release
Run the fleet updater with `--proxy` so SM283's remedy reaches the domains | D6 | operate
Run `--reapply-acls` on the fleet, then verify with `check --check-acl` | D6 | operate
```

# Reports

- `dimension-1-correctness.md`
- `dimension-2-code-quality.md`
- `dimension-3-test-coverage.md`
- `dimension-4-performance.md`
- `dimension-5-reliability.md`
- `dimension-6-security.md`
- `dimension-7-documentation.md`
- `dimension-8-policy.md`
