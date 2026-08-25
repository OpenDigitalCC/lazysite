---
title: "SM564: a group is judged by its reach, not its record"
subtitle: "The operator built a dedicated testing group rather than trust the existing ones. A group's declared capabilities and its EFFECTIVE reach are different things - SM570 proved an account holding no content capability could rewrite ACLs."
brand: plain
standard-margins: true
status: candidate
status-note: "ASKED BY THE OPERATOR 2026-08-25 via the site agent: verify whether the existing groups still make sense or want reorganising. The agent's angle is the right one - answer it EMPIRICALLY: for each group, what set of actions can a member actually call across all four surfaces, then compare with what the group is for. Live group data stays on the operator's sites (the tool is handed over, never the enumeration), so the deliverable is (1) a `group-reach` report in tools/lazysite-users.pl computed from the same four tables the dispatchers use, and (2) that report run against the STARTER's seeded groups here, with a written review. PLANNED for the cycle after the beta publish."
---

# The ask

Per group: the effective callable set on Manager UI, WebDAV, API and MCP, derived from the live capability tables, beside the group's stated purpose. Drift between the two is the finding.

# The proving test

A unit test seeding a group with one capability and asserting the report lists exactly the actions the four tables unlock for it - and nothing a channel flag alone would add.
