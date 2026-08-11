---
title: "Work plan - the boundary between done and not done"
subtitle: "Written 11 August 2026, after closing every partial. What is finished, what is next, and what is deliberately not being worked."
brand: plain
standard-margins: true
---

# Why this exists

The backlog had six filings at `partial`. Some had been partial for
months, and each one meant the same thing to a later reader: *stop and
work out which half is real*. Two of them had already been split once for
exactly that reason, and had drifted back into the same shape.

**There are now zero partials.** Every filing is `shipped` or
`candidate` - done, or not started. Where work genuinely remained, the
original was closed with a note saying what it delivered, and the
remainder was filed as its own request with its own scope. Nothing was
dropped; six new filings carry what the closures released.

This document is the boundary. Below it, nothing is half-finished.

# What was closed, and where the remainder went

```datatable
columns: Closed | What it delivered | Remainder went to
widths: 2.6cm | X | 3cm
bold: 1
tone: medium
---
SM103 | Recent-change markers (0.6.1) | [[SM221]] - real-time transport, designed properly
SM139 | The deb family, site-user provisioning, per-site channels (0.6.10-0.7.5) | [[SM272]] - apt repo + key custody
SM216 | Form quarantine + PII-free outcome logging (0.10.1) | [[SM273]] - cross-signal correlation
SM246 | Declared permission model, upgrade policy, file list, `check` verifying it (0.10.5) | [[SM274]] - the `--fix` repair decision
SM248 | Registry routing (0.10.4) + site identity (0.10.5) | nothing - the rest was an operator action, now [[SM270]]
SM263 | Four operator questions: three built, one withdrawn | [[SM275]] - the judgement-call rows
```

Two of those closures needed no successor, which is worth noticing: SM248
was finished and reading as unfinished, and SM103's remainder had already
been superseded by a better design.

## A second sweep: deferred halves inside SHIPPED filings

Closing the six `partial` records was not enough. A shipped filing can
still carry a deferred half in its note, which is a worse hiding place -
the status says done, so nobody reads on.

Sixteen shipped notes mentioned outstanding work. Thirteen were false
positives: they narrate history ("was not yet built when filed"), or point
at a successor that already exists ([[SM183]] -> [[SM266]], [[SM185]] ->
[[SM217]]). **Three were real, and are now filed:**

```datatable
columns: Was buried in | Work | Now
widths: 3cm | X | 2.5cm
bold: 1
tone: light
---
SM179 | P8, engine-chrome localisation - login, validation and 404 are English on every site whatever the content language | [[SM276]]
SM180 | The reciprocal "held by N groups / M users" counts on the Services page | [[SM277]]
SM200 | In-place regeneration of an expired connect code | [[SM277]]
```

A code sweep for `TODO`/`FIXME`/`XXX`/`HACK` in production Perl and shell
returned **nothing**, which is worth recording as a positive result rather
than an absence of output.

**The general lesson: "deferred" written in a shipped filing's note is
where work goes to be forgotten.** It should be a new filing at the moment
of deferral, not a sentence in the record of something else.

# The 0.10.6 cut

**Decision taken: wait for 0.10.6 rather than push 0.10.5.**

`v0.10.5` is tagged, built and gated, and it is not pushed. Two things
landed after the tag that change the calculus:

**[[SM270]]** - a Hestia vhost rebuild resets the docroot permissions, and
0.10.5's own release notes instruct every operator to rebuild. The
release creates the trap; the fix is not in it. Shipping 0.10.5 as tagged
means every Hestia upgrade carries a manual `lazysite-check --fix` step
that nobody will remember.

**[[SM271]]** - a transient dotfile at the repo root no longer breaks the
manifest gate. Not operator-visible, but it removes a class that cost
three misdiagnoses in one session.

Plus the SM269 phase 1 test work: the suite is 39 seconds faster and
`prove -j4` is green.

## What 0.10.6 needs

1. Version roll: `bump-version.pl` (VERSION -> 0.10.6, NEXT -> 0.10.7),
   `debian/changelog` entry. **This was missed for 0.10.5 and only caught
   at Phase B** - the tag sat on a tree declaring the previous version.
   `tmp/phase-b-*.sh` now refuses when they disagree.
2. CHANGELOG section for 0.10.6.
3. Status flips - SM270 and SM271 to `shipped` with commit refs.
4. Full gate.
5. Tag, then Phase B (manifest, SBOM, manpages, tarball, four debs).
6. Operator pushes.

The 0.10.5 tag and its artefacts stay as they are. Superseding it in
place would burn the version for nothing.

# Next work, in the order I would take it

## Now: finish the release

The gate is the long pole at ~80 minutes, of which coverage is 92%. Cut
0.10.6, push, and verify on a **Hestia** site specifically - the PT fix is
invisible on a site with no ACL store, so testing the wrong site proves
nothing.

## Then: the small, decided items

These are hours, not days, and each has a clear finish line.

```datatable
columns: Item | Why now | Size
widths: X | 5.5cm | 2cm
bold: 1
tone: light
---
[[SM274]] `--fix` repair | One decision unblocks it; the code is small either way | S
[[SM275]] docs-drift rows | Editorial, and one row may already be closed - confirm first | S
[[SM245]] brief sidecars to a plugin | Long-standing, self-contained | M
[[SM277]] two manager-UI follow-ups | Closed scope, and they batch with the UI trio below | S
[[SM276]] engine-chrome localisation | Needs a decision on who supplies translations first | M
`Notify.pm` coverage | Weakest module at 56.7\%, and [[SM231]] touches the same file - do them together | M
```

## Then: the decided-but-unbuilt UI trio

[[SM265]], [[SM266]], [[SM267]] and [[SM277]] are all manager JavaScript,
which the suite cannot reach. They should be done as one batch with a deliberate
manual test pass, not one at a time - the shared cost is the testing, not
the code.

## Then: SM269 phase 2 and 3

Phase 1 is done and its result is honest: parallelism improved the
developer loop and **did not move the gate**. Phase 0 measured why -
coverage is 92% of gate wall-clock, and the compile tax lives in CGI
subprocesses no harness can preload.

- **Phase 2** (the tier ladder) is small and useful: dev / review /
  release / scheduled, with Makefile targets.
- **Phase 3** is the only thing that changes the 80 minutes. It is also
  the one with a real risk of building a scheduled job nobody reads - the
  brief says so itself, and says that finding would be a result.

# Deliberately not being worked

Recording these so their absence is a decision rather than an oversight.

**[[SM272]] apt repository** - blocked on key custody, which is an
operator decision about who holds a signing key and what happens when
they are unavailable. Not a coding question.

**[[SM273]] spam cross-signal** - the constraints (no CAPTCHA, no
fingerprinting, no JS) are the point of the feature, and the remaining
parts need confirmation that the scanner signal is clean enough to
correlate against. Correlating noise makes the product worse.

**[[SM221]] real-time transport** - designed, not built, and correctly
so: SSE over CGI means a worker per open stream. It needs the daemon, and
the daemon needs a reason more pressing than presence markers.

**[[SM089]], [[SM090]], [[SM184]], [[SM217]], [[SM222]]** - candidates
with no current driver. Left alone.

# The two standing operator decisions

Neither blocks the release; both block a filing.

**SM274**: should `check --fix` widen permissions on a live site? My
recommendation is in the filing - repair only what demonstrably drifted
from the recorded install state, if the state can tell the two cases
apart, and otherwise stay report-only and document it.

**SM272**: where does the apt signing key live, and who can sign?

**SM276**: are engine-chrome translations bundled and maintained by the
project, or overridable per site the way layouts and themes already are?
The second is cheaper for the project and better for house style.

# What this document is not

It is not a schedule. Nothing here is estimated in days, because the last
week produced three unplanned items - a security review that blocked a
release, a live permissions incident, and a build-gate trap that cost
three misdiagnoses - and each was more valuable than what it displaced.
The order is a recommendation; the boundary is the point.

# The next release: integrity

**Theme, set by the operator on 2026-08-11: everything the product asserts
about itself should be true and checkable.** Not new capability - finishing
what is started, so nothing in the tree, the docs or the backlog is
half-true. Then the full eight-dimension sweep, and only then a minor
bump.

That theme has already found something. SM151 (first-class multi-site)
was `candidate`, note reading "awaiting review/merge/release", while
multi-site has been live for weeks - 26 references in the processor,
per-domain content roots and rewrites on 17 production sites, and SM248,
SM251 and SM268 H15 all built on top of it. The backlog was asserting
something false about the product. Corrected.

## Completing something started

Everything below is a successor to shipped work, not a new idea. Sized S
(hours), M (a day or two), L (more).

```datatable
columns: Item | Completes | Size | Importance
widths: X | 4cm | 1.4cm | 2.6cm
bold: 1
tone: medium
---
[[SM274]] `--fix` repairs, or says why not | SM246's third consumer - "install applies, check verifies, --fix repairs" is 2/3 true | S | HIGH - the design's own sentence is false until this lands
[[SM275]] remaining docs-drift rows | SM263/SM254 - docs that read wrong | S | HIGH - integrity of what we tell users
[[SM277]] two manager-UI follow-ups | SM180 + SM200 deferred halves | S | MEDIUM
[[SM276]] engine-chrome localisation | SM179 P8 | M | MEDIUM - a French site answers in English
[[SM266]] apply-confidence controls | SM183's carved-out manager JS | M | MEDIUM
[[SM267]] protected-sections panel | SM181's carved-out panel | M | MEDIUM - operators cannot see what is held back
`Notify.pm` coverage + [[SM231]] | the weakest-verified module, and the feature that owns it | M | HIGH - lowest coverage in the tree at 56.7\%
[[SM269]] phase 2, the tier ladder | phases 0-1 done | M | HIGH - tells us which tests to trust when, which the sweep needs
[[SM217]] first-class domain aliases | SM185 named it un-built | M | LOW - engine already supports it; this is UI
[[SM245]] briefs into a plugin | long-standing refactor of a shipped feature | M | LOW
[[SM273]] spam cross-signal | SM216 parts 3-5 | M | LOW - needs signal-quality confirmation first
[[SM272]] apt repository | SM139's distribution half | L | LOW - blocked on key custody
[[SM269]] phase 3, progressive coverage | the only thing that moves the 80-minute gate | L | MEDIUM - high value, real risk of building a report nobody reads
```

## What is NOT in this release

New capability, all of it: [[SM089]] 3D layout, [[SM090]] social
syndication, [[SM184]] email authoring, [[SM221]] real-time daemon,
[[SM222]] mini-init, [[SM265]] browser surface, [[SM208]] Figma helper.
Good ideas; none of them make the product more coherent than it is today.

## Suggested contents

The S items and the two HIGH M items: **SM274, SM275, SM277, SM269 phase
2, and the Notify.pm/SM231 pairing.** That is a coherent release - the
permission model becomes true, the docs stop misleading, two half-built
features finish, the test tiers become explicit, and the least-verified
module gets covered.

[[SM266]], [[SM267]] and [[SM277]] should go together whenever they go:
all three are manager JavaScript the suite cannot reach, so they share one
manual verification pass, and that pass is their real cost. [[SM153]]
(manager UI test guide) is the enabler for that and is worth pulling
forward if the trio lands.

## Verification before the minor bump

Three passes, in this order, because each feeds the next:

**1. Agent tests by the sites agent** - the product exercised by its
actual consumer, on real sites. Catches what unit tests structurally
cannot: whether an agent can accomplish a task end to end.

**2. A third adversarial round, locally.** Round 2 (SM268) found 26
defects against 0.10.4 and blocked that release. Round 3 must be told what
rounds 1 and 2 covered so it deliberately extends rather than repeats -
the register in the security memory exists for this. Candidate areas not
yet deeply covered: DoS and resource exhaustion, the git backends under
adversarial repo content, MCP tool-surface fuzzing, concurrent-request
races on the flat-file stores, and the multi-tenant boundary under the
shared-www-data CGI model.

**3. The eight-dimension non-functional sweep**, in the signoff order
defined in toolchain-development/TOOLCHAIN.md, with the docs dimension
maintaining CHANGELOG.md.

Only then the minor bump. A minor version that says "this is coherent"
should have been checked by its consumer, attacked deliberately, and swept
across all eight dimensions - in that order, because the sweep should not
be the thing that discovers a security defect.
