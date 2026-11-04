---
id: SM1311
title: "SM1311: a confined audit is of its scope"
subtitle: "audit_site walked the whole site for a grant confined to a scope: every domain's titles, links, stale files and rule keys. It now audits the scope, and a link to a page outside it is listed as outside the scope, never as broken."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 59, on SM1308's open point"
area: access
status-note: "SHIPPED (PENDING) on n739: audit_site takes the grant's scope roots for its page walk, its static-file walk and its rule keys; a link outside them is read on the domain the scope root serves, else listed in outside_scope_links. t/unit/mcp/68."
---

# What was asked

Ruling 59 (2026-11-04): audit_site is confined for a confined grant. Links to pages
outside the scope are reported as "outside your scope", never as broken.

SM1308 confined list_pages, list_files and search_files and left audit_site, which
walked the whole site for a confined grant. Confining its page walk alone would have
reported every link to a page outside the scope as broken.

# What shipped

- `audit_site` passes the grant's scope roots (`_walk_roots`) to each pass:
  - the page walk (titles, links, forms, duplicates, starter pages);
  - the walk for stale HTML and unprotected static files;
  - the rule keys that match nothing. Only keys inside the scope are reported, and only
    the grant's own content roots are offered as the repair.
- **A link outside the scope** is first read as a path on a domain served from one of
  the scope roots, since a content root's URLs are relative to it. A page there counts as
  a link target. Otherwise the link is listed in `outside_scope_links`
  (`from`, `to`), never in `broken_links`, and the target is not looked up. The audit says
  nothing about whether a page outside the scope exists.
- A confined grant's answer carries `scope_roots`. An unconfined grant's answer is
  unchanged and carries neither key.
- The tool description says so.

# Tests

- **t/unit/mcp/68** (new): a grant confined to `content/mine`.
  - It is told of the broken link in its scope and nothing else. It sees no page outside
    the scope, stale HTML only in the scope, and rule keys only in the scope.
  - A link to an existing page outside the scope and one to a missing page outside it are
    both in `outside_scope_links`, and neither is broken.
  - A link `/c` resolving on the scope root's domain is neither.
  - An unconfined grant's audit is the control: it is unchanged.

With the change reverted, two of the three subtests fail (the control passes).
