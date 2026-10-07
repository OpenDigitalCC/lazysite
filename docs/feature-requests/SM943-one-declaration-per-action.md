---
id: SM943
title: "SM943: One declaration per control-API action"
subtitle: "Adding an action touches 13 files and about 15 edit sites; declare it once and generate the rest."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: control-api
status-note: "SHIPPED (PENDING) 2026-10-07: stage 1 on n259, stages 2-3 on n274. Every per-action fact, the MCP twin and its hints are declared on %ACTION and derived for both CGIs, each proved equal before its copy went; the consistency lints keep their rules and one completeness check replaces their copies. Open: the 17 MCP reads audited unlike their API twins; read_nav's gate (SM568)."
---

# Measured

Adding `form-uploads-save` (an ordinary action) touched 13 files: the dispatch branch, `%KNOWN_ACTION`, `%MUTATING` / the audit skip list and `%COOKIE_CAP` in `lazysite-manager-api.pl`; `ControlApi/Actions.pm` (caps and params); the MCP tool table and its annotations; `Capabilities.pm`; two generated reference docs; and the tables in lints 14, 23, 98 and `t/unit/lib/16`, `18`. Every missed site is found one handoff at a time (SM938 D4/D5 in 0.15.2 each needed several rounds).

# Proposal

Each action is declared once in `ControlApi/Actions.pm`: name, capability, parameters, `mutates` or `read`, audited or not, MCP twin name and annotations, handler sub. The dispatcher's tables, the MCP tool list, the guarantee tables and the reference docs are derived from it. The consistency lints that exist only to keep those copies in step (14, 22, 23, 58, 98, and the action tables in 16/18) shrink to one check that the declaration is complete.

# Done when

Adding an action is one declaration plus its handler and test; the lints named above are retired or reduced, and a test proves the derived tables equal today's hand-kept ones before any copy is removed.

# Built

Stage 1 (n259): the manager API's ten per-action tables are fields on `%ACTION` in `ControlApi/Actions.pm`, and the CGI derives each from it.

Stage 2 (n274): `mcp => 'tool'` on an action names its MCP twin - on the action rather than the tool, because the module is the one place both CGIs and the tests can load, and three of the twin's four hints are facts already on the action. readOnly, destructive and changesAccess are derived; openWorld is declared as `mcp_open_world`. `lazysite-mcp.pl` builds `%ANNOTATE` from the twins plus its own rows for the 24 tools with no API twin, and its audit skip list from readOnly less 17 named reads. The unlocks map stopped claiming `save_data_row` and `delete_data_row` for `write_data`, and `read_nav` for `manage_content`.

Stage 3 (n274): lints 14, 22, 23, 58 and `t/unit/lib/16` lost the assertions that compared a value with itself or repeated another file's; every rule they held stays. One completeness check of every declaration is in `t/unit/lib/200`.

# Open

- The 17 MCP reads the MCP trail records while the API trail skips their twins (`read_form_submissions`, `read_data_rows`, `list_briefs`, `read_notices` and the rest; `describe_capabilities` while `whoami` is skipped). Kept as they were; which trail is right is a ruling.
- `read_nav` is gated on `manage_nav` alone (SM421), while SM568 ruled reading the navigation a content read and `nav-read` admits `manage_content`. Admitting it on MCP would widen a gate, so it is a ruling too.
- A `write_data` door on MCP's row tools needs `Manager::Data::row_write_refusal` in them first.
