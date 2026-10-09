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
status-note: "SHIPPED (PENDING) 2026-10-07: stages 1-3 (n259, n274). RULED 2026-10-09. Ruling 1 built (n309): a read is audited on neither door unless refused or failed; t/lint/23 holds both trails to one declaration. Ruling 2 (the structured nav read needs no capability) HELD: ungated, a domain-confined grant reads every domain's nav, ruled: confine host first, then build it. Downloads stay audited."
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

# Ruled 2026-10-09

The release manager ruled both questions this filing left open.

Ruling 1 - audit
: "Audit is useful to see when a person or agent has made material behaviour changes, authentication events and errors. General site activity is of less interest and creates noise. Surfaces should be consistent. Drop all 17."

Ruling 2 - the navigation read
: "As nav is public, do we need a cap to be able to read it? manage_content and manage_nav stay separate. Surfaces should be consistent." Confirmed in detail: the STRUCTURED nav read - API `nav-read` and MCP `read_nav` - needs no capability beyond the surface's base access, identical on both; writing (`nav-save`, `set_nav`) stays `manage_nav`; WebDAV GET of the raw `nav.conf` stays `manage_nav`; `manage_content` no longer grants anything nav-specific.

Ruled 2026-10-09, on what ruling 1 left
: The five control-API downloads (`backup-download`, `data-export`, `file-download`, `file-zip-download`, `site-backup-download`) STAY audited: each takes a full copy of the site or its data off the server, which is material, not general activity. They are the rule's one named class.

Ruled 2026-10-09, on the hold below
: "Confine host, then ruling 2": the nav read and write confine `host` to the caller's domain scope first, as the other host-addressed actions do (a security fix of its own); ruling 2 is then built on top - no capability for the structured read, scope still applied.

# Built (n309)

Ruling 1. MCP's `%AUDITED_READ` is gone and its skip set is the read-only tools with none named, so the seventeen reads stop writing a row on success, as their API twins never did. A read that is refused or errors is recorded on both doors: MCP wrote no row for a read its handler refused (only for a gate refusal), and the control API's audit block ran for POST only, so a refused read over GET - how a token client reads - wrote none. Writes are unchanged. `t/lint/23` section 6 holds the trails to one declaration: MCP's rule must name no tool and nothing else may write its skip set, and every twin is audited on both trails or on neither. `regenerate-registries` is recorded there as the one twin that differs, a write outside this ruling (unaudited on the API by `audited => 0`, audited over MCP as every write tool is). `t/unit/mcp/28` and `t/unit/manager/206` drive both doors.

# Open

- Ruling 2 is HELD, not built. Ungating the structured read lets every grant on the surface read EVERY domain's navigation through `host`, including a grant confined to one domain, where today only `manage_nav` holders can. Host-addressed actions elsewhere (`domain-set`, `remap-save`, the site packages, the data surface; SM578, SM648, SM802) refuse a domain outside the caller's scope, and the nav actions do not check it at all - measured 2026-10-09: a grant scoped to one domain with `manage_nav` read and REPLACED another domain's navigation through `nav-save` and `set_nav`. Ruled the same day: confine first, then build ruling 2 (above).
- A `write_data` door on MCP's row tools needs `Manager::Data::row_write_refusal` in them first.
