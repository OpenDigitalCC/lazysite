---
id: SM1290
title: "SM1290: a page previews in a theme that is not active"
subtitle: "MCP preview_page rendered with the active theme only, so a designer could check a new theme on real pages only by rebuilding its tokens locally. preview_page and the manager's page preview take `theme` now: an installed theme to render with, read-only, refused for one that is not installed for the page's layout."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the lazysite.io site agent, inbox 2026-10-22-forms-validator-and-page-var-quotes.md (K-4)
area: mcp
status-note: "SHIPPED (PENDING) on n735: preview_page `theme` (saved page and draft) and the cookie preview action's `theme`; LAZYSITE_PREVIEW_THEME read by the processor on a single-shot CGI GET, applied in resolve_layout_vars over page, section and site, reported in X-Lazysite-Preview-Theme; the render writes nothing (_draft_requested); needs manage_themes or manage_layouts. t/unit/mcp/60, t/integration/335."
---

# What happened

K-4, from the designer who built the `control` theme for lazysite.io against
the design kit: "`preview_page` renders with the active theme only, so the
designer could preview only locally, rebuilding the token block from theme.json
by hand. The site agent staged a layout copy with its own theme copy to get a
real-page preview." The manager has had a theme preview since SM071, but it is a
signed cookie for a browser session (`preview-grant`), which an MCP connector
has no use for (lint 23 records `preview-grant` as API-only for that reason).

# What shipped

- **`preview_page` takes `theme`.** The saved page, or a draft passed as
  `content` (SM1030), renders with that installed theme in place of the site's,
  the section's (SM812) and the page's own `theme:` - a theme preview asks what
  the page looks like in that theme, so it wins over a pin. The result carries
  `theme` and says nothing was activated or written.
- **The manager's page preview takes it too.** The cookie `preview` action, the
  twin of `preview_page` on the manager side, accepts `theme` with the same gate
  and refusals.
- **How it renders.** The caller sets `LAZYSITE_PREVIEW_THEME` for the
  processor, which honours it only on the single-shot CGI path for a GET, as it
  does a draft (an environment variable is not something a visitor sets).
  `resolve_layout_vars` applies the theme when it is installed for the layout
  the page actually renders with, and records why not otherwise; `output_page`
  reports that in `X-Lazysite-Preview-Theme`, which the caller reads and refuses
  on.
- **Read-only.** `_draft_requested` is true for a theme preview, so every writer
  a render reaches refuses as it does for a draft: the page cache, the
  content-type and dependency records, the registries, the cached error pages,
  the form rules and secret, the access log, the remote-layout cache and the TT
  compile cache. `main()` also keeps it off the page cache.
- **Refused** for a name that is not a theme name, a theme installed under no
  layout (`not-found`), and a theme not installed for this page's layout, or a
  page with no layout or a remote one (`theme-not-installed`, naming the
  layout). A refusal hands back no HTML.

# The capability

`preview_page` is `manage_content`. Previewing in another theme shows what that
grant cannot otherwise see: which themes are installed (`list_themes` is
`manage_themes`) and what each renders as. So `theme` also needs
`manage_themes` or `manage_layouts`, the pair `preview-grant` already asks for
to show a manager a theme that is not active. Nothing new is reachable with
them that was not before. Without `theme`, `preview_page` is unchanged. The two
capabilities' descriptions say so.

# Tests

- t/unit/mcp/60: over the MCP CGI, the saved page, a page pinned to the active
  theme and a draft each render in the named theme; every file under the site
  is byte-identical afterwards; a content-only grant is refused `forbidden`;
  an uninstalled theme, one installed for another layout only and a malformed
  name are refused with no render; the four refusals wrote their audit rows and
  nothing else; without `theme` a content-only grant previews in the active
  theme. With the processor as before every rendering assertion fails; with only
  `_draft_requested` reverted, the two write checks fail (`lazysite/cache` is
  created).
- t/integration/335: the manager's `preview` with `theme`, as a signed-in
  person: renders in the theme and writes no page cache, a content-only manager
  is refused, and the two install refusals answer. With Preview.pm as before,
  they fail.
