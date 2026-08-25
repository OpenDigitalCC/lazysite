---
title: "SM531: a url page is a cache source"
subtitle: "Four cache walks disagree on whether a .url page owns its render, so a wildcard invalidate keeps a stale page the processor would re-render."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): one _cache_source_exists($base) (true for a .md or .url sibling) answers for all four walks - the primary and per-host cache listing, the wildcard sweep, the single-path branch and the activation sweep - so a .url render is listed with a source, cleared by invalidate('*') and clearable by path, while an .html with neither sibling stays legacy content (SM133). Proving test t/unit/manager/100-a-url-page-is-a-cache-source.t drives a .md, a .url and an orphan .html through all four and pins the five call sites. FOUND 2026-08-25 by the themes structural review, PROVEN by probe tmp/tl-probe-url-cache.pl; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. The processor renders page.url (lazysite-processor.pl 2271, 2554). In Manager/Themes.pm, _invalidate_html_cache at 811 treats .url as a source and deletes the render; action_cache_invalidate('*') at 1697-1698 only knows .md and keeps it; action_cache_list at 1628-1632 reports it has_source: 0; the single-path branch at 1762 and 1797 refuses a marker-less .url render as not-a-cache. Probe output: invalidate('*') a.html=gone b.html=kept, then _invalidate_html_cache() b.html=gone. Fix: one _cache_source_exists($base) used by all four walks."
---

# The finding

The processor renders `<page>.url` (`lazysite-processor.pl 2271,
2554`). `_invalidate_html_cache` (`Manager/Themes.pm 811`) treats `.url`
as a source and deletes the render; `action_cache_invalidate('*')`
(`Manager/Themes.pm 1697-1698`) only knows `.md` and keeps it;
`action_cache_list` (`1628-1632`) reports it `has_source: 0`; the
single-path branch (`1762, 1797`) refuses a marker-less `.url` render as
`not-a-cache`. Probe output: `invalidate('*') a.html=gone b.html=kept`,
then `_invalidate_html_cache() b.html=gone`.

# Why it matters

Correctness: an operator who invalidates everything expects every render
to go. A `.url` page kept by the wildcard walk is served stale until some
other path happens to clear it, and the cache listing tells the operator
it has no source at all.

# The proving test

NEW `t/unit/manager/100-a-url-page-is-a-cache-source.t`: after
`action_cache_invalidate('*')`, `ok(!-e "$doc/b.html")`.

# Fix shape

One `_cache_source_exists($base)` used by all four walks, so the module
holds a single definition of what counts as a source.
