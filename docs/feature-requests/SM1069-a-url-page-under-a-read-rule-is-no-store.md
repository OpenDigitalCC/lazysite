---
id: SM1069
title: "SM1069: a .url page under a read rule is no-store, and a rule is found by its path's ancestors"
subtitle: "Two findings from SM1068. The .url output path never passed the protected flag, so a gated .url page was answered cacheable and its render read and written beside its source. And the registry rebuild walked every rule key for every page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-13
raised-by: developer, SM1068 findings; release manager 2026-10-13
area: processor
status-note: "SHIPPED (0.15.5), n563: the .url branch passes the protected flag to process_url and output_page; a gated .url render is neither read from nor written to the render cache. _acl_entry_for looks up the path's ancestors through a per-store index of normalised keys. t/integration/240-241, t/unit/processor/128-129."
---

# A. A `.url` page under a READ rule

## What was wrong

The `.url` branch of the processor called

    output_page( _inject_admin_bar_live( $page, $url_path ), $ct, undef, undef, $status );

with no protected flag, and `process_url` read its render cache (the TTL read,
and the stale copy on a failed fetch) and wrote it, whoever asked. The section
gate (`_acl_refused`) ran first, so a reader outside the list was still
refused. But for the listed reader:

- the answer carried `no-cache, must-revalidate` (or `public, max-age` for a
  page TTL), never `no-store, private`, so any HTTP cache could keep it;
- the render was written to `<base>.html` beside the source. For a source in
  the document root, that is a file the front end serves to anyone.

It is the rule the `.md` path already follows (SM223, SM1068), so no new ruling
was needed.

## Reproduced

t/integration/240, before the fix: a `.url` page under `{"sec":{"read":
["alice"]}}`, a fresh render in its cache slot, requested by alice. Red on
"answered no-store, private" and on "not from the shared render cache".

## The fix

- `lazysite-processor.pl`: the `.url` branch passes `$protected` (the same
  flag the `.md` branch uses: the gate's `_acl_governed`, plus preview, draft
  and the auth surface) to `process_url` and `output_page`, and skips
  `write_ct` for it.
- `lazysite-processor/pipeline.pm`: `process_url` takes `$protected`. When set,
  it neither serves the TTL cache nor the stale cache on a failed fetch, and
  returns the render without writing it or updating the registries.

A `.url` render carries no viewer (the request's auth context is set only for a
`.md` page), so SM1068's no-viewer rule for the cache is met already.

## Every other output path

| Path | Answer | Gap? |
|---|---|---|
| `.md` page (`lazysite-processor.pl:1438`) | `$protected`, cache neither read nor written | no |
| page cache hit (`try_serve_cache`, `:783`, `:811`) | reached only when not protected | no |
| `.url` page (`:1456`) | was unprotected | **fixed here** |
| static-HTML fallback (`:1481`) | `_acl_governed` gives no-store, private; served verbatim, writes no cache | no |
| statics (`_serve_content_static`, 200 and 304) | `_static_cache_control`: no-store when governed; writes no cache | no |
| registries and feeds (`_serve_registry`: sitemap.xml, feed.rss, feed.atom, llms.txt) | `public, max-age`; built only from pages `_registry_hidden` passes, with no identity, so the same for everyone | no |
| source alternate (SM825, `text/markdown`) | after every gate; always `no-store` | no |
| 404 (`not_found`) | rendered from 404.md through `process_md`, so SM1068's no-viewer rule holds; not gated content | no |
| refusals - 403, 402, login bounce, ACL static refusal, `forbidden()` | protected (no-store) | no |
| PDF and downloads | the processor has no PDF path (the manager builds PDFs, t/integration/122); a download is a static, above | no |

# B. The rule found by its ancestors

## What was slow

`_acl_entry_for` found a folder rule by walking every key in the store and
keeping the longest matching prefix. A registry rebuild asks it for every page
(draft, then `'see'`), so the rebuild was pages x rules: about 1 s of the 3 s
first render on SM1068's 1,800-rule fixture.

## The fix

The candidates are exactly the prefixes of the path that end before a `/`, so
they are looked up, longest first, in an index of the store's keys by their
normalised spelling (leading and trailing slashes off; the site-wide rule is
still checked on its own, last). The exact key, the page stem (SM268 H14), the
modes (`'read'`, `'draft'`, `'see'`, none) and the order are unchanged.

The index is kept only for the map `_acl_map` hands out, which no reader
changes, in one slot holding that map (so its address is not reused while the
index names it). Any other map - a caller's own, which it may change - is
indexed afresh on each call, at the cost of the walk it replaces. The
fail-closed state is untouched: `_acl_governed`, `_acl_governing_key` and
`_acl_allows_read` answer a failed load before they reach the resolver.

Where two spellings of one folder both govern (`sec` and `/sec/`), the walk
took whichever the hash gave first; the lookup takes the first in sort order.
Both are rules on the same folder.

## Measured

SM1068's fixture: 1,800 posts, a write rule each, a `/` write rule, the
starter's registry templates. A post rendered right after the registry cache is
removed (so every registry is rebuilt), three trials, after one warm-up
request. CHILD CPU seconds, not wall time: the host was running a whole-suite
run (load average about 20), which made wall time meaningless (13 to 17 s
before, 12 to 13 s after).

```datatable
columns: Render | Before | After
widths: 6cm | 4cm | 4cm
---
post, registries stale | 5.27 / 5.70 / 4.94 | 1.57 / 1.61 / 1.55
post, registries fresh | 0.32 / 0.30 / 0.33 | 0.30 / 0.31 / 0.30
```

Both runs listed all 1,801 pages in the sitemap. Script:
`tmp/n563-measure-stale.pl` in the worktree.

# Tests and sabotage

- t/integration/240 - a `.url` page under a read rule: no-store, private; not
  answered from the cache; no render written; anonymous still sent to log in.
  Control: under a write-only rule the cache still serves it.
- t/unit/processor/128 - `process_url` in process, the remote stood in for: a
  protected render is returned and written nowhere, and never served from the
  cache; unprotected it is cached as before.
- t/unit/processor/129 - the lookup against the old walk, kept in the test as
  the reference: 13,200 questions over 300 seeded stores (every mode, key
  spellings, nested folders, exact and stem keys, the site-wide rule, a doubled
  slash); and a caller's own map changed between calls.
- t/integration/241 - a read rule and a draft flag two folders up keep their
  pages out of the sitemap, with write-only rules between; a page under
  write-only rules alone is listed.

Sabotaged one at a time (backup in tmp/sab-bak/n563/, restored with cp and
checked with cmp), each red: A1 the `.url` output without the flag (240); A2 a
gated `.url` read from the TTL cache (240, 128); A3 a gated `.url` render
written (128); B1 the shortest ancestor taken (129); B2 the lookup ignoring the
mode (129, 241); B3 the index kept for any map (129).

# Related

SM1068 (read/draft only; the store read once per change), SM223, SM268 H14,
SM287, SM837 (a failed fetch answers 503), SM825 (source alternate).
