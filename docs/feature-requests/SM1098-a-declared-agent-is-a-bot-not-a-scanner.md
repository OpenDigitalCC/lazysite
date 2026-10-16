---
id: SM1098
title: "SM1098: a declared lazysite agent is a bot, not a scanner"
subtitle: "A client sending User-Agent lazysite-agent/<partner-id> is recorded as bot however many missing pages it asks for."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.5 test plan, T9)
area: stats
status-note: "SHIPPED on n607: plugins/stats.pl _tally_batch; t/unit/plugins/49."
---

# What happened

The 0.15.5 test plan results, "Found outside the rows":

> Test traffic is classed as scanner. Anonymous probes of draft-folder 404s
> put this agent in the scanner class (40 visits, 51% of the day's window),
> not bot.

The site briefing and the MCP server instructions tell an agent to set its
User-Agent to `lazysite-agent/<partner-id>`, which "keeps your hits out of the
HUMAN visitor counts - they are recorded as bot traffic rather than dropped".

`classify()` honours that. The visitor-level promotion in `_tally_batch`
(SM213 signatures, SM332 five distinct missing paths in five minutes) did not
consult the user-agent at all, so a declared agent that asked for five missing
draft pages was promoted to `scanner` and its earlier requests were reached
back and rewritten to match.

# What shipped

Both ingesters now mark a record `agent` when its user-agent matches the
declared-agent pattern, and `_tally_batch` skips promotion for such a record.
The promotion key already includes the user-agent, so a browser behind the
same address is unaffected, and every other client keeps the scanner
heuristics unchanged. `t/unit/plugins/49` pins the rule with an undeclared
client running the same sweep as the control.
