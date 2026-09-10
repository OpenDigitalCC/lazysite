---
id: SM827
title: "SM827: brief - one Agent Skill, authored from the docs we already have, as an experiment"
subtitle: "Rec 3 of the knowledge-standards survey, accepted 2026-09-10 as an experiment worth running. Package the build method as a single Agent Skill so a team's existing agent tool can pick it up by dropping in one folder, rather than the agent having to come to the site's docs. Authored from existing material, measured before anything is maintained, and held for feedback."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-10
raised-by: release manager, from the knowledge-standards survey
area: distribution
status-note: "HELD FOR FEEDBACK 2026-09-10. Accepted as an experiment rather than a programme: ONE skill, authored from documents that already exist, then measured. The wider question of what the skills and AGENTS.md landscape means for lazysite is SM828, deliberately separated so the experiment can be judged on its own result rather than on the argument for the category. Not scheduled; no engine change."
---

# What is proposed

Package lazysite's how-to knowledge - the APP-FOUNDATION build method, the
authoring practice, the connector workflow - as an **Agent Skill**: a
discoverable folder (`SKILL.md` plus resources) that an agent loads when the task
matches, per the open skills standard.

The outcome for a user: whichever agent tool their team already uses picks up the
lazysite method by dropping in one folder. **The institutional knowledge travels
to the agent, instead of the agent having to come to the site's docs.** For the
agency audience - the Figma and design-transfer case - that is a distribution
channel for the method itself rather than another page about it.

# Why this is an experiment and not a programme

The survey's own framing, and it is the right one: our documents already serve
MCP-connected agents well. **The skill's marginal value is reach into workflows
that are not MCP** - a repo in someone's editor, a coding agent with no
connection to the site at all.

That is a real gap and an unmeasured one. So: **one skill, authored from material
that already exists, and then measured.** A family of skills maintained on
speculation is the failure mode to avoid, and it is the one this shape is chosen
to prevent.

# What the experiment must produce to be judgeable

Recorded now, because an experiment with no stated result is a thing that gets
declared successful:

1. **One skill folder**, authored from existing documents rather than written
   fresh. If it cannot be assembled from what we already publish, that is itself
   the finding - it would mean the method is not written down as clearly as we
   think.
2. **A statement of what it does NOT cover**, so a reader is not misled into
   thinking a skill replaces the MCP surface or the site briefings.
3. **A way to tell whether it was used.** This is the hard part and it should be
   decided before authoring, not after: a skill dropped into someone's repo
   reports nothing back by design. Candidate signals - a distinctive entry point
   it tells the agent to call, a documented URL it fetches - each of which is a
   deliberate choice with a privacy shape, and none of which should be added
   quietly.
4. **A decision rule**: what result would mean "author more" and what would mean
   "stop". Without one, the experiment cannot end.

# What it is not

- Not an engine change. Nothing in lazysite is modified by authoring a skill.
- Not a replacement for the MCP connector or the `ai-briefing` set, which are the
  instruction layer for agents that ARE connected.
- Not a commitment to the standard. One folder is cheap to abandon.

# Held for feedback

Accepted as worth doing and **not scheduled**. The release manager has asked for
this brief and [[SM828]] to circulate before anything is authored.

# Provenance

`inbox/archive/2026-09-10-knowledge-standards-ruled.md`, Recommendation 3
("EVALUATE, THEN LIKELY DO"), accepted as an experiment 2026-09-10. The survey
notes the standard is recent and asks that its resource URLs be re-verified at
audit; **they have not been verified here.**
