---
title: "SM110 - domain aliases (shared backend, different render)"
subtitle: "One site, many domains - same files/users/plugins, different look and feel"
brand: plain
---

::: widebox
A **domain alias** is an additional host that serves the *same* lazysite site - same
files, users, plugins, backend - but may render differently: its own theme, its own
nav (or the default), its own site name, and content that can adapt via template
variables on the matched alias. Distinct from multi-site (separate docroots): here it
is one docroot, and only *what is rendered* differs. This lets, e.g., a blog host and
a main host share assets and management while looking and behaving differently.
:::

## Model

- **Match by Host header.** An alias is any domain; the processor selects the active
  alias from the request Host. A default applies when no alias matches.
- **Per-alias overrides (a subset of site config):** `site_name`, `theme` (and
  possibly `layout`), and `nav` (assign a nav file to the alias, or fall back to the
  default `nav.conf`). Everything else (users, plugins, content files, WebDAV/MCP
  surfaces) is shared - the backend is essentially common.
- **Content adaptation via TT:** expose the active alias to page templates (e.g.
  `[% alias %]` / `[% alias.name %]`), so a single content file can branch on the
  alias for small differences without duplicating the page.
- **Shared assets, different chrome:** because the theme/layout differ per alias but
  the content + assets are shared, the same managed site presents two (or more) faces.

## Access control (to design)

The operator wants per-alias access scoping: only a certain group can manage the
files or settings *for* an alias. This needs design - a sketch:

- An alias may name an owning/managing **group**; membership gates who can edit that
  alias's config (nav/theme/name) and possibly which files it exposes.
- This intersects the existing capability + group model (SM095): alias-scoping is a
  new dimension on top of per-account capabilities.
- **MCP / WebDAV must be considered:** a connector/partner request also arrives on a
  Host; the active alias (and its access group) should scope what that partner can
  read/write, not just the browser UI. Since the files are shared, this is about
  *visibility/authority per alias*, not separate storage.

## Open questions

- Where aliases live (lazysite.conf block, or an `aliases.conf`), and the manager UI
  to add/edit them.
- Whether an alias can restrict the *content subtree* it serves (a blog alias serving
  only `/blog`), or only changes chrome over the whole tree.
- Interaction with the published-site auth domain (members/login) per alias.
- Caching: the render cache key must include the alias (the same path renders
  differently per alias).

## Status

Queued - design. Substantial: a Host-to-alias resolver in the processor, per-alias
config + cache-key change, TT exposure of the alias, and an access-group dimension
that must reach the control API / MCP / WebDAV - sequence after [[SM095]]
(group-based capabilities), which it builds on.
