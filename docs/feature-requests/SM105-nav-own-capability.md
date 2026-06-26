---
title: "SM105 - navigation as its own capability"
subtitle: "Grant nav editing with content (default) or separately"
brand: plain
---

::: widebox
Editing the site navigation is currently gated by **`manage_content`** (the MCP
`set_nav` tool requires it; an operator editing nav in the manager UI bypasses
capabilities entirely). That is a reasonable default - nav usually goes with content -
but nav is arguably its own concern (it can belong with content *or* with
theme/layout). Give it its own capability, defaulting to inherit from content so
nothing breaks.
:::

## Current behaviour (confirmed)

- **Connector / partner**: `set_nav` requires `manage_content` (lazysite-mcp.pl). So
  a partner with content rights can change nav.
- **Operator (manager UI)**: `nav-save` is not in the capability map; operators bypass
  the capability gate, so any operator can edit nav.

## Proposal

- Introduce **`manage_nav`** as a distinct capability.
- **Effective nav permission = `manage_nav` if set, else `manage_content`** (inherit),
  so every account that can edit content today keeps editing nav with no migration.
- Surface it as a toggle in the Users-page "Publishing access" group (it can then be
  granted with content - the default - or independently, e.g. alongside
  theme/layout for a designer who owns the chrome but not the pages).
- Apply on both surfaces: the `set_nav` tool's `cap`, and the partner gate for
  `/lazysite/nav.conf` writes.

## Why

A site may want a "navigation editor" who shapes the menus and the chrome (theme /
layout) without write access to page content, or vice versa. Coupling nav to content
forces an all-or-nothing grant.

## Status

Queued. Bounded: a new capability key with content-inheriting default, one `cap`
change in the MCP, the partner gate for nav.conf, and a toggle in `users.md`. Pairs
with [[SM095]] (group-based capabilities) - `manage_nav` would be group-assignable
too.
