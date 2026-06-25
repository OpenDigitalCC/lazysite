---
title: "SM087 - Connector editing ergonomics (from live ChatGPT use)"
subtitle: "Make AI-driven site editing safer, higher-level and self-checking"
brand: plain
---

::: widebox
Detailed feedback from a ChatGPT connector session editing the barn site (multiple
linked files: homepage, area page, nav, sitemap, llms.txt, briefs, deletes). The
connector exposes mostly filesystem primitives; these items raise it to a
page-aware, self-checking, transactional editing surface. ChatGPT's single
highest-value ask: **a staged changeset workflow with diff, validation,
generated-index refresh and rollback.**
:::

## Tier 1 - safer primitives (quick wins)

1. **Patch editing** (was the #1 ask) - **DONE**: `replace_text(path, old, new)`
   MCP tool (errors if `old` absent; reports replacement count). Follow-ons:
   `insert_after_heading`, `replace_between(start, end)`, `apply_unified_diff`.
2. **Content search / grep** (#6) - **DONE**: `search_files(query, path)` MCP tool
   (file/match-capped, snippets). Follow-ons: `find_links_to(path)`.
3. **Generated-index refresh** (#3) - **DONE**: a content delete/save/move now
   invalidates the generated registries (sitemap.xml, llms.txt, feed.*) so the
   processor rebuilds them fresh on the next request - no more stale references to
   a deleted page. (The registries previously only refreshed on a 4h TTL.)
4. **Cache / publish status** (#9): per-page last-rendered time, cache state,
   whether sitemap/llms/feed are stale, the public URL, and a "source saved but
   render not refreshed" flag.
5. **Better read/write diagnostics** (#10): distinguish connector error vs
   permission vs deny-list/safety vs transient vs lock vs malformed path in the
   error returned (one read was blocked then worked on retry - opaque).

## Tier 2 - higher-level + validation

6. **Page-aware API** (#7) - **DONE**: `read_page`, `list_pages`, `create_page`,
   `delete_page` (deletes the .brief + reports remaining references),
   `rename_page` (with `update_links` rewriting internal links across pages).
   Remaining: `set_nav` (nav.conf is not rewritten by `rename_page`).
7. **Validate before save** (#8) - **DONE**: `validate_page(path|content)`, also
   auto-run by `write_file` (warnings/issues returned in the write result) -
   unterminated front matter, missing title, invalid/typo'd form rules, and the
   **public-data warning** (Wi-Fi passwords, postcodes/addresses, phone numbers).
   Follow-ons: unclosed HTML, broken TT, invalid JSON-LD; auto-run on write.
8. **`audit_site`** (#4) - **DONE**: broken internal links, orphan pages, missing
   titles, stale generated HTML, and duplicate content blocks (same paragraph on
   multiple pages - the repeated-reviews case). Follow-ons: nav-vs-sitemap
   coverage, near-duplicate (fuzzy) detection.

## Tier 3 - bigger builds

9. **Transactional changesets** (#2, the headline ask): `begin_changeset` ->
   write/delete -> `preview_diff` -> `commit_changeset` / `rollback_changeset`,
   with validation gating the commit. Best realised on the **git backend plugin
   ([[SM085]])** - a changeset is a working tree + commit; rollback is `git
   reset`; diff is `git diff`. This unifies #2 + #3 + #8.
10. **Rendered preview / screenshot** (#5): `render_page(path)` (server-side HTML),
    `screenshot_page(path, viewport)`, `validate_layout` - catch spacing/wrapping/
    mobile issues invisible in source (e.g. an unspaced highlight strip). Headless
    render is the heavy dependency.

## Sequencing

Tier 1 items are small and compounding - do them next. Tier 2 (page API +
validation + audit_site) is the bulk of the day-to-day safety. Tier 3 changesets
ride on [[SM085]]; screenshots are a separate, heavier track. Together these turn
the connector from "filesystem with auth" into a safe content-management surface.

## Claude.ai assessment (2026-06-25, separate live session)

A grounded Claude.ai review of the *deployed* connector mapped to status:

- **Tool manifest / discovery** (their #1) - **DONE**: whoami echoes `tools: [...]`.
- **Write-time validation/lint** (#2) - `validate_page` done; auto-run on write is
  the follow-on.
- **Authenticated render/preview** (#3) - **DONE**: `preview_page(path)` renders
  the page server-side (fresh, no-cache) and returns its HTML, so verification
  stays in-channel - no web fetch. (Public-view render; protected pages show the
  auth gate.)
- **Partial-edit** (#4) - **DONE**: `replace_text`.
- **401 disambiguation** (#5) - **DONE**: sign-in-incomplete vs credential-invalid
  + `error.data.reason`.
- **copy_file** - **DONE**. **get_permissions** (read ACL) - **DONE**.
- **Config-write cache invalidation** - **DONE**: a nav.conf save clears all
  caches + flags `cache_rebuilt`. (Follow-on: config-set / lazysite.conf too.)
- **search_files** - **DONE** (earlier this cycle).
- **ACL model discoverability** - partly: `get_permissions` reads state; a richer
  describe/schema is a follow-on.

Two processor bugs the agent met through the connector (capture - fix in the
processor, expose via `preview_page`/`validate_page`):
- `:::`-fenced divs don't run block-level Markdown on their content (a heading
  inside a box leaks literal `##`).
- `select:` options truncate at the first space - mitigated by quoting
  (`select:"Dog friendly,No dogs"`, shipped 0.4.11); the unquoted case still bites.

## Status

Raised 2026-06-25 (ChatGPT + Claude.ai live use). Most of Tier 1/2 + the Claude.ai
quick wins shipped. Remaining high-value: `preview_page`, validate-on-write, the
fenced-div processor fix, and the page-API verbs (create/delete/rename).
