---
id: SM1372
title: "SM1372: the primary site's content leaves out the other domains' folders"
subtitle: "An account given nothing, or granted the primary's row, read the whole document root as its content, and so reached and listed every secondary domain's folder through it. The primary's content is now the document root less the other domains' content roots, for reaching a path and for listing one."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "rulings 126 and 137 (release manager, 2026-11-06), from the SM1332-SM1334 register entry's residual risk; planned as n759"
area: auth
status-note: "SHIPPED (0.16.6) on n759: DomainAccess::foreign_root_of, asked by Common (outside_all_scopes, caller_may_reach_path), the MCP gate and walks and WebDAV authorise (ruling 126); Files action_list, MCP list_files and WebDAV PROPFIND leave the roots out (ruling 137). The operator is the operator group (SM991). t/unit/manager/446, t/unit/dav/39, t/unit/mcp/74."
---

# What happened

On an instance serving more than one domain, each secondary domain's content
lives in its own folder under the document root (`sites/<host>/` as a rule).
An account that reaches the primary site - one granted nothing (no domain names
its group), or one whose group is on the primary's row - read the whole document
root as its content. By path that held every other domain's folder, so the
account read and wrote another domain's pages through the primary, and listed
them. The SM1332-SM1334 register entry (2026-11-05) recorded it as residual risk.

# The rulings

Ruling 126
: The primary's content is the document root less the other domains' content
  roots. An account reaching the primary does not reach a domain's root it is
  not granted; one granted that domain keeps it.

Ruling 137
: Listings leave those roots out too: the manager's file browser, MCP
  `list_files` and a WebDAV PROPFIND, wherever a caller reaching the primary
  lists the document root or `sites/`. The operator group and accounts granted
  the domain still see them. The operator is the operator group (SM991), as
  built, confirmed as intended.

# What changed

The rule
: `Lazysite::Auth::DomainAccess::foreign_root_of( domains, scopes, path )`
  answers the other domain's root a path lies in, for a scope list that
  reaches the document root (empty, or holding the primary's grant) and names
  no scope covering the path.

Reaching a path (ruling 126)
: `Lazysite::Manager::Common` asks it in `outside_all_scopes` and
  `caller_may_reach_path` for every caller but the unconfined operator, so the
  manager API's dispatch gate, the file actions, the zip download, the sections
  listing, PDF parts and the form and brief rules hold to it. MCP asks it at the
  path gate and in its document-root walks (`list_pages`, `search_files`).
  WebDAV's `authorise` refuses such a path unless the account is in the
  operator group. The refusal names the folder and how to grant the domain.

Listing a folder (ruling 137)
: `Manager::Files::action_list` leaves out an entry that is another domain's
  root the caller is refused, by the request's scopes or those a door names.
  MCP `list_files` answers through it with the grant's scopes. A WebDAV
  PROPFIND leaves such a child out of its Depth 1 listing, with the operator
  group exempt as at `authorise`.

Tests
: `t/unit/manager/446` (the rule, the doors and the file browser listing),
  `t/unit/dav/39` (WebDAV with the real resolver: GET, PUT and PROPFIND) and
  `t/unit/mcp/74` (`list_files` through the CGI). Each fails with its change
  reverted.

# ADR 0007

No trigger fires: no interface, sign-in method, dependency or data is added. The
change narrows an existing content-path rule and what a listing names. The
register entry in `docs/SECURITY.md` (2026-11-06, SM1372) records it.
