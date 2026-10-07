---
id: SM943
title: "SM943: One declaration per control-API action"
subtitle: "Adding an action touches 13 files and about 15 edit sites; declare it once and generate the rest."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: control-api
status-note: "Filed 2026-10-07 at the release manager's direction, from the development-cost analysis. Size L. Planned in WORK-PLAN-0153 group E."
---

# Measured

Adding `form-uploads-save` (an ordinary action) touched 13 files: the dispatch branch, `%KNOWN_ACTION`, `%MUTATING` / the audit skip list and `%COOKIE_CAP` in `lazysite-manager-api.pl`; `ControlApi/Actions.pm` (caps and params); the MCP tool table and its annotations; `Capabilities.pm`; two generated reference docs; and the tables in lints 14, 23, 98 and `t/unit/lib/16`, `18`. Every missed site is found one handoff at a time (SM938 D4/D5 in 0.15.2 each needed several rounds).

# Proposal

Each action is declared once in `ControlApi/Actions.pm`: name, capability, parameters, `mutates` or `read`, audited or not, MCP twin name and annotations, handler sub. The dispatcher's tables, the MCP tool list, the guarantee tables and the reference docs are derived from it. The consistency lints that exist only to keep those copies in step (14, 22, 23, 58, 98, and the action tables in 16/18) shrink to one check that the declaration is complete.

# Done when

Adding an action is one declaration plus its handler and test; the lints named above are retired or reduced, and a test proves the derived tables equal today's hand-kept ones before any copy is removed.
