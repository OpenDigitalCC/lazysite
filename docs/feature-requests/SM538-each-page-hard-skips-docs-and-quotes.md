---
title: "SM538: _each_page hard-skips docs and quotes"
subtitle: "Every page under docs/ or quotes/ is invisible to list_pages, audit_site and rename_page link updates."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): _each_page now skips only engine territory - Manager::Common::path_is_reserved (lazysite/) plus lazysite-assets/ and the manager UI tree - so docs/ and quotes/ pages are listed, audited and link-updated; proving test in t/unit/mcp/01 (list_pages names docs/guide.md and still hides lazysite/). FOUND 2026-08-25 by the mcp structural review, PROVEN by probe tmp/mcp-probe-anomalies.t; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. _each_page at lazysite-mcp.pl 1842 excludes manager, img, quotes and docs alongside the engine directories; git log -S dates the list to the original SM087 commit (593598d), the first site's folder names. On lazysite.io the thirty documentation pages under /docs/ are absent from list_pages, unaudited by audit_site (orphans, titles, forms, starter pages) and untouched by rename_page update_links; a page under /quotes/ on any site is likewise invisible. Fix: drop the two names and ask Manager::Common::path_is_reserved instead, with a test that a page under docs/ is listed."
---

# The finding

`_each_page` (`lazysite-mcp.pl 1842`) excludes `manager|img|quotes|docs`
alongside the engine directories. `git log -S` dates the list to the
original SM087 commit (593598d), where it recorded the first site's folder
names. On lazysite.io the thirty documentation pages under `/docs/` are
therefore absent from `list_pages`, unaudited by `audit_site` (orphans,
titles, forms, starter pages), and untouched by `rename_page update_links`.
A page under `/quotes/` on any site is invisible in the same way.

# Why it matters

Correctness: the MCP surface promises a whole-site view, and an agent that
lists or audits the site reasons from an answer that silently omits a
folder. A rename that updates links leaves every reference under `docs/`
pointing at the old URL.

# The proving test

From the table row: a test that a page under `docs/` is listed; use
`Common::path_is_reserved` – `list_pages` on a site with `docs/guide.md`
names that page.

# Fix shape

Drop `docs` and `quotes` from the exclusion, and decide what is engine
territory by asking `Manager::Common::path_is_reserved` rather than a
literal list in the MCP file.
