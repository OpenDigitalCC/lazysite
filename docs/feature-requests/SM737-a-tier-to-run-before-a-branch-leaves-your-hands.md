---
id: SM737
title: "SM737: a tier to run before a branch leaves your hands"
subtitle: "Nothing sat between finishing work and offering it for review, so the first thing to notice a formatting slip or an undocumented class was the release gate hours later. Four tiers, chosen from timings rather than taste, and a policy that says what each is capable of finding."
brand: plain
standard-margins: true
status: shipped
---

# The moment this fills

A branch is developed, then handed to `vcs-review`. **Nothing was in between.**
So the first thing to notice a lint failure was the release gate - hours later,
after the eleven-minute suite and sometimes after two hours of coverage - or a
human reading the diff.

That is expensive in the obvious way and worse in a subtle one: **a failure
found at the gate arrives with a release attached**, so the choice is to hold
the cut or to fix in a hurry.

# The tiers, and where they came from

Measured, not chosen. Across the 110 lint files:

- **Four account for 65 of 88.8 seconds** - the two perlcritic sweeps and the
  two changelog checks. Each compiles the tree or walks git history.
- **The other 102 run in 14.6 seconds combined.**

93% of the lints for 16% of the time. That distribution is the fast tier; nobody
picked it.

| Tier | Cost | When |
| --- | --- | --- |
| `fast` | ~4s | While you work |
| `review` | ~45s | Before offering a branch |
| `suite` | ~4 min at `-j4` | When behaviour changed |
| release | ~2.5 h | A cut |

`scripts/pre-review.sh`, committed beside `install-hooks.sh` and excluded from
the payload for the same reason: a site has no use for the thing that checks a
branch.

# Why the lints, specifically

**Of 739 test files ever added, 94% arrived in the same commit as the code they
test.** They are regression insurance. Only 43 were written against code that
already existed - the only shape that can discover anything - and **53% of those
are lints**.

Three independent confirmations: the gate register's one recorded FAIL is
`perlcritic`; every gate failure hit across one long session was a lint and not
one was a unit test; and the release that took three attempts was stopped by
`t/lint/63`.

**So the fast tier is not the cheap tier - it is the tier most likely to find
something.** That is the argument for running it often, and it is the opposite
of the intuition that cheap checks are shallow ones.

# Proved on itself

The `review` tier's first run **refused its own new file**: `pre-review.sh` was
unclassified, so the manifest build failed. That is the tool doing on its first
execution exactly what it exists to do, and it is why the manifest build is in
the tier rather than left to the gate - it has caught a stray backup file, a new
docs directory and two new tools in one session.

# What is deliberately not here

**No blast-radius selection.** The tiers are about WHEN a fixed set runs, never
about running a subset chosen from a diff. `docs/architecture/test-tiers.md`
records the evidence: SM702's lockout was invisible because every existing test
put its user in a group holding the capability directly, so a selector keyed on
changed files would have picked the auth tests and they all passed. And the
checks that discover things are global by nature - a selector would never pick
them, because their value is that they are tied to no change.

**No enforcement.** Nothing makes anyone run it. The honest mechanism would be
`vcs-review` refusing a branch whose review tier has not passed, and that tool
lives in another repository - it is the release manager's to change. Recorded
here rather than left implicit, because *advice without a mechanism accumulates
the thing it advises against* is a lesson this project has already learned once,
on the 283 merged branches nobody deleted.

# And what no tier can do

Three defects found this month were invisible to every tier and were all found
from outside: a PDF render with no caller, theme assets that never reached a
content-root domain, and a write guard present on one stack and absent on the
other. The policy document says so plainly, so nobody reads the tiers as a claim
of sufficiency.
