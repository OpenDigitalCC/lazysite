---
id: SM828
title: "SM828: brief - what the agent-knowledge landscape means for lazysite, beyond one experiment"
subtitle: "The wider half of Rec 3, separated so the experiment in SM827 can be judged on its result rather than on the argument for the category. The survey's own position is that the industry converged on legible markdown with light structure - which is what lazysite already is - so the question is not whether to adopt a standard but which boundary to meet it at. Held for feedback."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-10
raised-by: release manager, from the knowledge-standards survey
area: distribution
status-note: "HELD FOR FEEDBACK 2026-09-10, and deliberately NOT a plan. It records the landscape, what lazysite already does that meets it, and the questions that would have to be answered before any of it became work. Separated from SM827 so that one skill can be tried without first agreeing a position on the category."
---

# The position the survey took, which is worth keeping

> the industry has converged on legible markdown with light structure as the way
> agents consume knowledge - which is what lazysite already is.

That is the whole of it, and it is why this brief recommends nothing ambitious.
The conclusion drawn from it - **thin, boundary-level interop, and an explicit
decline of the heavyweight alternatives** - is a position rather than a plan, and
it has held for three of the four recommendations already ruled.

# What lazysite already does, which needs no work

Recorded because it is the baseline any proposal has to beat:

- **robots.txt, sitemap.xml and llms.txt**, generated from the registries.
- **The `ai-briefing` set and the onboarding briefs** - the instruction layer,
  site-shaped. This is the AGENTS.md idea, already implemented, for the case
  where the agent reaches the site.
- **The MCP connector with `describe_capabilities`** - the protocol-level
  knowledge surface, and the reason agents already work well here.

These are why the survey's recommendations are thin: the platform is already on
the right side of the convergence.

# The three shapes a standard can be met at

The useful distinction, because each has a different cost and a different failure:

**At the site**, for an agent that arrives. Already done. The failure mode is
staleness - a briefing that describes an engine two releases old - and it is
handled by generation rather than authorship.

**At the boundary**, as an export. [[SM826]] (OKF) is this shape and is held: the
format is immature and has no consumers a lazysite site would be read by. The
failure mode is building an export nobody reads, and the mitigation is to wait
for adoption rather than to guess at it.

**At the agent**, as a skill. [[SM827]] is this shape. The failure mode is
maintenance: a family of skills, authored on speculation, each drifting from the
docs it was copied out of. That is why SM827 is one skill and a measurement.

# The questions this brief does not answer

Named rather than resolved, because they are the ones that decide whether any of
this becomes work:

1. **Who is the audience that is NOT already served?** The survey names agencies
   and non-MCP workflows. That is plausible and unmeasured, and everything here
   rests on it. If the answer is "nobody in practice", the correct action for the
   whole category is nothing.
2. **What is the maintenance contract?** A skill or an export copied from the
   docs is a second copy of the method. This codebase has a filing for every
   time a second copy was kept by hand. If it cannot be GENERATED from the
   documents it describes, that is an argument against, not a detail.
3. **How does a standard's adoption get re-checked?** [[SM826]] is held on
   adoption and EntityMap is watched on adoption, and neither has a trigger that
   would fire. "Revisit if it gains consumers" is only a plan if somebody looks.
4. **What is declined, and stays declined?** The survey declines the vector-store
   and GraphRAG direction on the standing analysis, with activation triggers that
   have not been met. Worth restating whenever this is revisited, so the decline
   does not quietly lapse.

# What this brief recommends

**Nothing yet, deliberately.** Run [[SM827]] as one experiment, answer question 1
with its result, and bring this back. The alternative - agreeing a position on
the category first - would commit the project to a programme on the strength of a
survey rather than a measurement.

# Provenance

`inbox/archive/2026-09-10-knowledge-standards-ruled.md`, the framing and closing
sections. Separated from the experiment at the release manager's request so the
two can be judged apart. Resource URLs in the survey are noted there as
unverified and remain so.

# Updated 2026-09-10: question 2 now has a live instance

Question 2 above - *what is the maintenance contract for a second copy of the
method?* - was written as a general worry. It has a concrete case now.

**[[SM817]] renames `plugin` to `extension` across the operator surface.** Any
skill, export or bundle authored from today's documents would carry the old word
after that pass lands, and nothing would tell its readers. That is the failure
this brief predicted, arriving before anything was built - which is useful,
because it can be watched rather than argued about.

So the maintenance question becomes answerable by observation: **when the surface
pass happens, note how much of it a published skill would have had to follow.**
If the answer is "almost none", the copy is cheap to keep. If it is "most of it",
then a skill has to be generated from the documents rather than authored from
them, and that is a different and larger piece of work than the experiment.

**One thing to state plainly given the rename:** none of this changes the
platform's position. The survey's finding was that lazysite already IS legible
markdown with light structure, and that is as true of an extension as it was of a
plugin. The vocabulary moving is a maintenance fact about copies, not a change to
what the platform offers an agent.

Still recommending nothing, and still held.
