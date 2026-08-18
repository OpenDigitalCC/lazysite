---
title: "SM302 - A review finding should carry the command that checks it"
subtitle: "Five reviews have each re-verified the last one's findings by hand. The checks are mostly one-liners, they are written nowhere, and the one thing this project has proved is that a record nobody mechanised does not survive."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18 as tools/lazysite-review-verify.pl plus a findings.json per review. THE THREE-STATE RESULT IS THE POINT: fixed, still-open, and COULD NOT BE CHECKED - a check that could not run is never counted as either, and a missing command (exit 127) or a signal is the case a naive tool reads as "non-zero, therefore still open", delivering a wrong verdict with confidence. Unrunnable fails the run, because a review whose checks cannot run has told the next reviewer nothing. A finding with no verify is reported as not-mechanical rather than omitted - "we did not automate this one" is a fact the next reviewer needs and an absence is not. Convention stated at the point of use: the expression exits 0 when the finding is FIXED, because the opposite convention is equally natural and getting it backwards inverts every verdict. Seeded with the four checks SM302 itself quotes, which are real and were run by hand during the 0.10.8 and 0.10.9 reviews. DEVIATION FROM THE FILING: JSON rather than YAML, because JSON::PP is core and a hand-rolled YAML subset would be a parser to maintain for no gain. FILED 2026-08-15 out of the 0.10.9 review. Nothing started. This is the review applying its own central thesis to itself: the 2026-08-14 review's headline finding was that every mechanised control had held and every hand-maintained record had rotted - and its own findings are hand-maintained prose that the next assessor re-checks by hand."
---

# SM302 - the review is a record, and records rot

## Where this comes from

Every eight-dimension review opens by verifying the previous review's findings
as fixed or open rather than assuming. That discipline is correct and it is
entirely manual: the assessor reads last time's prose and works out, per
finding, what would prove it.

Across the 0.10.8 and 0.10.9 reviews that was roughly thirty checks, run
interactively as one-off greps. Most were one-liners:

```
F6.2  grep '^### 2026' docs/SECURITY.md | tail -1        # register current?
F7.1  grep -oE '\*\*0\.[0-9.]+\*\*' docs/FEATURES.md | head -1
F5.1  newest rehearsal date vs the newest STABLE cut
D4    grep captured_at dist/config/bench-baseline.json
```

None of them is written down anywhere. Each review reinvents them, and a
finding whose check is reinvented is a finding that can be re-checked
differently - or silently not at all.

## What to build

A `verify:` expression on each finding, and a tool that runs them.

```yaml
- id: F7.2
  title: POLICY.md cites a superseded review
  severity: warn
  side: build
  verify: "! grep -q '2026-07-01-eight-dimension' docs/POLICY.md"
```

`tools/lazysite-review-verify.pl <review-dir>` then re-runs every mechanical
finding against the current tree and reports fixed / still-open / not-mechanical.
The assessor spends their time on the judgement calls, which is where an
assessor is actually worth something.

Three properties matter:

- **Not every finding is mechanical**, and the format must say so rather than
  pretend. "The threat model does not describe the architecture" needs a person.
  Marking it `verify: manual` is information, not a gap.
- **A finding that cannot fail is not a finding.** The same rule the compliance
  gate is held to: each `verify:` should be demonstrated failing against the
  tree that produced it.
- **Severity and side belong here too** (see below), because they are what a
  projection needs and they were exactly what the last one lacked.

## The second thing this fixes

The 2026-08-14 review closed by projecting 7 PASS / 1 WARN for 0.10.9. The
result was 3 PASS / 4 WARN / 1 REFUSE, and four of the five misses were
build-side work that was named and never scheduled.

The projection failed because **every finding looked equally movable**. "Fix a
stale documentation pointer" (two minutes) and "name an Article 14 owner and
rehearse the reporting path" (a person, a rehearsal, a legal determination) sat
in the same list at the same weight.

Carrying `severity`, `side` (build or operate) and an effort estimate would let
a projection say what it actually knows: *these three are build-side and small,
so they move if scheduled; that one needs a named person and a date.*

## Care needed

- **Do not let the format eat the prose.** The value of these reviews is the
  argument - why a finding matters, what it would cost to be wrong. A findings
  file that becomes a YAML list of assertions has thrown away the part worth
  reading. The structured fields sit alongside the narrative, not instead of it.
- **The verify expression must not become the finding.** A check that passes is
  evidence the specific symptom is gone, not that the underlying problem is
  solved. `t/lint/46` exists because a non-recursive check answered confidently
  and wrongly.

## Related

[[SM283]] (the review that produced the gate this generalises),
`tools/lazysite-compliance.pl` (the same move applied to the compliance
records), `docs/review/2026-08-14-eight-dimension-0.10.9/` (the projection that
missed).
