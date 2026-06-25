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

6. **Page-aware API** (#7) - **PARTIAL**: `read_page(path)` (parsed front matter +
   body + brief + public URL) and `list_pages` (title + registries + URL) done.
   Remaining: `create_page`, `delete_page(clean_references)`,
   `rename_page(update_links)`, `set_nav` - the link-rewrite is the harder part.
7. **Validate before save** (#8) - **DONE**: `validate_page(path|content)` -
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

## Status

Queued. Raised 2026-06-25 from live ChatGPT use. Item 1 (replace_text) shipped.
