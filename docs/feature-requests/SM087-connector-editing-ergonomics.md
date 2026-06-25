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

1. **Patch editing** (was the #1 ask) - replace exact text instead of rewriting a
   whole file. **DONE**: `replace_text(path, old, new)` MCP tool (errors if `old`
   absent; reports replacement count). Follow-ons: `insert_after_heading`,
   `replace_between(start, end)`, `apply_unified_diff`.
2. **Content search / grep** (#6): `search_files(query)` / `grep(pattern, path)` /
   `find_links_to(path)` - walk text content, return path + line snippets. Caps +
   excludes binary/generated.
3. **Generated-index refresh** (#3): deleting/renaming a page leaves `sitemap.xml`,
   `llms.txt`, `feed.atom`, search index stale. Investigate WHEN these regenerate;
   add explicit `rebuild_sitemap` / `rebuild_llms` / `rebuild_feed` /
   `rebuild_search_index`, and warn when deleting a page still referenced by them.
4. **Cache / publish status** (#9): per-page last-rendered time, cache state,
   whether sitemap/llms/feed are stale, the public URL, and a "source saved but
   render not refreshed" flag.
5. **Better read/write diagnostics** (#10): distinguish connector error vs
   permission vs deny-list/safety vs transient vs lock vs malformed path in the
   error returned (one read was blocked then worked on retry - opaque).

## Tier 2 - higher-level + validation

6. **Page-aware API** (#7): `list_pages`, `read_page(slug)` (front matter + body +
   brief + registration), `create_page`, `delete_page(slug, clean_references)`,
   `rename_page(old, new, update_links)`, `set_nav`. Treats the site as pages, not
   a bag of files.
7. **Validate before save** (#8): malformed YAML front matter, invalid form-field
   syntax/rules, unclosed HTML, broken TT blocks, invalid JSON-LD, missing
   title/subtitle - and a **public-data warning** (phone, Wi-Fi password, full
   private address) since guest-instruction uploads carry operational secrets.
8. **`audit_site`** (#4): broken links, pages linking to deleted files, duplicate /
   near-duplicate content (repeated review/testimonial blocks), orphan pages, nav
   entries pointing nowhere, sitemap entries for missing pages, SEO/title gaps,
   forms/CTA coverage.

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
