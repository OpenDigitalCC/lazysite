---
id: SM736
title: "SM736: coverage is skipped when every input that decides it is unchanged"
subtitle: "The coverage stage took two hours and twenty minutes on the 0.11.11 cut, against eleven minutes for the entire correctness suite - 85% of a release, spent re-deriving an answer that cannot have changed. It is a pure function of a knowable input set, so when that set is byte-identical to a run that passed, it is skipped."
brand: plain
standard-margins: true
status: shipped
---

# The measurement that prompted it

| Stage | 0.11.11 |
| --- | --- |
| compliance | seconds |
| **correctness suite** (745 files, 12,276 tests) | **11 minutes** |
| bench | seconds |
| **coverage** | **2 hours 20 minutes** |
| manifest, SBOM, packages, tag | minutes |

**Coverage is about 85% of a cut, and it discovers nothing.** It is a ratchet: it
answers "has coverage fallen", and the analysis this week found that the checks
which actually FIND defects are lints and cross-surface consistency checks, not
this.

# Why it is safe to skip, and only this

Coverage is a **pure function** of a knowable set: the eight gated CGIs, the
library they call into, every test that exercises them, and the floor config.
`tools/coverage-inputs.pl` digests exactly that. If the digest matches a run that
passed, the percentage cannot have moved.

**The correctness suite is NOT skipped, and the same argument does not reach
it.** A gate result is a fact about a tree AT A TIME: date-sensitive tests are a
known class here - the 0.11.0 work found five stats tests that failed daily for
ninety minutes after UTC midnight. Coverage is a structural measurement and does
not have that property; correctness does. Skipping the suite on a hash would be
the same reasoning applied where it does not hold.

## Absence refuses, in four ways

The stage RUNS when: there is no record; the record is unreadable; the digest
differs; or the recorded run FAILED. **The only path to a skip is a positive
match against a pass**, and each of the four was proved by trying it.

`LAZYSITE_COVER_FORCE=1` overrides, for when somebody doubts the record.

# Where it actually fires

**Not between two releases.** Any real release changes something in `lib/` or
`t/`, so the digest moves and the stage runs. That is correct and it is most
cuts.

**On a promotion.** A stable cut from the same commit as the beta that passed
differs only in the version stamp, which is not in the input set - so the digest
matches and two hours and twenty minutes disappear. That is exactly the case the
release manager described: *if there are no changes for stable, no need to run
all the tests.*

# The lint, and what it prevents

`t/lint/111` compares the CGI list in the digest tool against the one in
`coverage.sh`'s floor loop. **If they drift, the digest attests a set that is
not the measured set** - and a skip would then be licensed by a hash of the
wrong files. That is a silent wrong answer, which is the worst kind.

It also asserts the below-floor exit comes BEFORE the record is written, so a
failing run cannot leave a record that lets the next one skip.

Sabotage-verified: dropping one CGI from the digest fails three assertions.

# Found while building this

`cover_db-suite.log` - a coverage run artefact that lands at the repo root - was
**unclassified**, so running coverage locally and then building a manifest
refused. Pre-existing, and any developer running the stage by hand would have
hit it. Excluded.

# What this does not do

It does not make coverage faster, reduce what is measured, or lower a floor.
The stage is unchanged when it runs; the change is that it stops running when
the answer is already known.
