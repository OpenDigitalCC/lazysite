---
id: SM956
title: "SM956: A visit of more than five pages at under ten-second gaps is classed as a bot"
subtitle: "An owner-ruled rule for the visitor classifier."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: the sites agent (xisl.com), carrying the owner's ruling, 2026-10-06
area: analytics
status-note: "Owner rule 2026-10-06: >5 pages in a visit, all gaps <10 s, is not a person. Edge case: a visit with fewer than two gaps stays in its class. Since 0.15.2 the class is unattributed (R10, SM941), so the rule moves visits from unattributed to bot."
---

# The rule (owner, 2026-10-06)

> a visit with more than five pages at under ten-second gaps is not a person

Both conditions: more than five page requests in one visit, and every gap
between consecutive requests under ten seconds. Three quick pages stay; a long
slow visit stays.

# Supporting measurement (B, one site)

On xisl.com 43% of the requests in the then-HUMAN class were 404s, from clients
presenting a browser User-Agent.

# Since 0.15.2

R10 renamed the class: there is no `human` class, the visits are
`unattributed` (SM941, counting basis 4). This rule moves visits from
`unattributed` to bot.

# Requirements

1. A visit with one or two requests has no gaps to judge and keeps its class; an
   empty gap list is never "all gaps under ten seconds".
2. Reclassified visits stay visible in the bot class, with a reason, so the
   change can be inspected.
3. The counting basis advances, so counts before and after are not compared as
   like with like; the changelog says the unattributed count will step down.

# Done when

The classifier applies the rule; tests cover six fast pages (bot), five fast
pages (unchanged), six pages with one slow gap (unchanged), and a one-request
visit (unchanged).
