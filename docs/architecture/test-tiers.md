---
title: "Test tiers: what to run when, and why"
subtitle: "Four tiers, chosen from measurements rather than intuition - what each costs, what each is capable of finding, and the one thing none of them can do. SM737."
brand: plain
standard-margins: true
---

# The four tiers

| Tier | Command | Cost | When |
| --- | --- | --- | --- |
| **fast** | `scripts/pre-review.sh fast` | **~4s** | While you work |
| **review** | `scripts/pre-review.sh review` | **~45s** | Before offering a branch |
| **suite** | `scripts/pre-review.sh suite` | **~4 min** at `-j4` | When behaviour changed, not only its description |
| **release** | `tools/release.sh build` | **~2.5 h** | A cut |

# Why these boundaries and not others

**The tiers come from timings, not from taste.** Across the 110 lint files:

- **Four files account for 65 of 88.8 seconds** - `perlcritic`, `perlcritic-security`, `changelog-commit-refs-exist`, `changelog-entries-sit-in-their-release`. Each compiles the tree or walks git history.
- **The other 102 run in 14.6 seconds combined.** They read the tree.

So 93% of the lints cost 16% of the time, and that is the fast tier. Nobody
chose it; the distribution did.

# What each tier can actually find

This matters more than the cost, and it is measured too.

**Of 739 test files ever added to this project, 94% arrived in the same commit
as the code they test.** They are regression insurance: they exist so a fixed
defect stays fixed. Only 43 were written against code that already existed - the
only shape that can *discover* something - and **53% of those are lints**.

Three independent confirmations of the same pattern:

- The gate register's one recorded FAIL is `perlcritic`.
- Every gate failure encountered across one long working session was a lint -
  tidy, perlcritic, the changelog pair, the class contracts, the manifest build.
  Not one was a unit test.
- The release that took three attempts was stopped by `t/lint/63`, then by a
  human.

**So the fast tier is not the cheap tier. It is the tier most likely to find
something**, which is why it is the one to run often.

# The release tier, and why coverage is last

| Stage | 0.11.11 |
| --- | --- |
| correctness suite (745 files, 12,276 tests) | 11 min |
| **coverage** | **2 h 20 min** |

**Coverage is about 85% of a cut and discovers nothing** - it is a ratchet
answering "has coverage fallen". SM736 skips it when every input that decides it
is byte-identical to a run that passed, which fires on a promotion and correctly
does not fire between two real releases.

**The correctness suite is never skipped**, and the reasoning that licenses
skipping coverage does not reach it: a gate result is a fact about a tree AT A
TIME, and date-sensitive tests are a known class here. Coverage is a structural
measurement; correctness is not.

# The rule that keeps this honest

**Selection is for the inner loop. It is never how the gate decides what to
run.**

The temptation is to compute a blast radius from a change and run only the
affected tests. This codebase has direct evidence against it: SM702's lockout was
invisible because *every existing test* put its user in a group holding the
capability directly. A selector keyed on changed files would have picked the auth
tests - and they all passed. The gap was fixture shape, not selection.

Worse, the checks that actually discover things are **global by nature**: does the
changelog agree with the backlog, do four surfaces agree, does every advertised
URL fetch, is every class defined. A selector would never pick them, because
their value is precisely that they sweep everything and are tied to no change.

# What no tier can do

**Three of the defects found this month were invisible to every tier**, and all
three were found from outside by an agent testing a running instance:

- A PDF render with **no caller at all** - eleven sabotage tests passing against
  a function nothing invoked.
- Theme assets that **never reached a domain with its own content root**, on
  every release since the asset mirror existed.
- A write guard present on one stack and **absent on the other**.

No amount of running these tiers would have found any of them. That is the
argument for the field pass, and the reason a field finding should always be
asked one question: *could a lint have caught this?* A yes turns a class of
defect into something nobody has to test again. A no identifies a surface that
genuinely needs a running instance, which is where field time is worth spending.
