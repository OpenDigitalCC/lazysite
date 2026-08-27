---
title: "SM515: every MCP tool declares its gate"
subtitle: "list_briefs and delete_brief shipped with no cap and a misnamed schema key. The dispatcher treats a cap-less tool as channel-only: any authenticated partner could delete a brief."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-25 by the structural review of lazysite-mcp.pl (a probe proved it): the two SM508 tools used the key `schema` (silently ignored) instead of `inputSchema`, and declared no `cap`; tools/call gates on `$tool->{cap}` and treats its absence as channel-only, so a manage_themes-only partner reached delete_brief, and inputSchema:null was published so arguments were never validated. Exposed on edge in 0.10.30 and 0.10.31 - the field tests ran with manage_content and could not see it; no client site had briefs enabled. FIXED before the 0.10.32 beta build (stopped and relaunched for it): both tools carry cap => manage_content and a real inputSchema; t/lint/85 asserts every tool-table entry declares both keys and never `schema`; t/unit/mcp/01 pins the refusal for a webdav-only bearer and schema validation for a bogus argument. SEVERITY CORRECTED by the agent's floor-row sweep on 0.10.31 (2026-08-25): a principal holding NO capabilities called list_briefs and received the site's brief inventory (paths, sizes, orphan flags) - a disclosure in its own right - and delete_brief reached the action (a not-found proved the gate was passed; a real path would have deleted), while read_brief beside them was correctly gated. Not 'any partner, a manage_themes grant included' - any authenticated principal including one holding nothing. Class, not instance: the parity lints read the keys that were present, so a missing key was invisible until a probe asked."
---

# The defect

Two tools, both mine (SM508), with `schema` instead of `inputSchema` and
no `cap`. The dispatcher's rule - a tool without a cap is a channel-only
tool - meant any authenticated partner could call `delete_brief`, and the
null published schema meant nothing validated its arguments.

# The fix, and the class

Both tools now declare `cap => 'manage_content'` and a real
`inputSchema`, as their siblings always did. `t/lint/85` asserts every
entry in the tool table declares both keys - there is no legitimate
cap-less tool; introspection lives outside the table - so a typo cannot
open a door again.
