---
title: "SM311 - a page's data files are dependencies the cache did not track"
subtitle: "The documented tt_page_var pattern updated the page exactly once. After that the author edited the data, saw nothing change, and had no way to find out why."
brand: plain
status: shipped
status-note: "SHIPPED on claude/sm305-principal-picker-and-polish, and the 0.10.10 build was HELD to include it. FILED 2026-08-15 from a site-agent report measured on edge/0.10.9 during a mock customer engagement (inbox/archive/2026-08-15-data-file-changes-do-not-invalidate-the-page.md). Covers json: and scan: completely - scan: records both the matched files (so an EDIT is seen) and the directories walked (so an ADD or DELETE is seen), because neither alone is sufficient. url: has no local mtime and is reported as unprovable, which routes it to the TTL branch - the only freshness mechanism such a page has. Perf gate: all ops within tolerance, render_cache_hit_ms 92.6 ms against the 2026-07-02 baseline."
---

# SM311 - the artefact's inputs change only when the artefact does

## What was found

A page pulls structured data into its template with front matter:

```yaml
tt_page_var:
  services: json:/data/services.json
```

Editing the JSON did not update the page. The rendered HTML is cached, the cache
was fresh whenever it post-dated the page's own `.md` and `lazysite.conf`, and a
change to a file the page merely **reads** is neither. The stale page was served
indefinitely.

Measured by a site agent on edge running 0.10.9:

```datatable
columns: Action | Cards rendered
widths: 9cm | X
bold: 1
tone: medium
---
Initial publish, 8 items in the JSON | 8
Add a 9th item, upload the JSON alone | 8
Flush the page (GET then byte-identical re-PUT) | 9
---
```

The upload succeeded, the JSON served correctly at its own URL, and the page
carried on serving the previous render.

## Why it is worse than ordinary cache staleness

**It defeats the feature's only reason to exist.** Writing the list into the page
would have worked perfectly. The data file exists so that a non-technical owner,
a scheduled export, or anyone without page-editing rights can change what the
page shows - and that is exactly the caller for whom the failure is invisible and
unfixable. They did what they were told to do, the file is correct on the server,
and the page disagrees with it.

**The workaround needs a capability the data editor may not hold.** Recovering
means saving the page, which is `manage_content`. An account scoped to the data
directory cannot clear the cache its own edit invalidated.

**It fails silently in the safe-looking direction.** Nothing errors. The page is
valid, fast and wrong, which is the hardest state to notice and the one that
survives review.

**It is SM251 one layer down.** A registry rebuilds during page *processing*, so
requesting the registry does not refresh it. A page re-renders when the page is
*saved*, so changing what it renders *from* does not refresh it. Both assume an
artefact's inputs change only when the artefact does.

## The fix: record what the render read

The cache-hit test gains a third term. The first two are the `.md` and the conf;
the third is everything the page consumed.

**A record, not a re-check.** `scan:` globs up to 200 `.md` files and reads each
one's front matter, so proving a scan-backed page fresh means knowing about
**edits inside those files**, not just additions and removals. A directory mtime
cannot see an edit. Redoing the walk on the cache-hit path would put a 200-file
traversal with front-matter parsing on the hottest path in the engine. So the
render - which has already done the walk - writes down what it consumed, and the
cache path stats that list.

```datatable
columns: Source | What is recorded | What that catches
widths: 2.4cm | 5.6cm | X
bold: 1
tone: medium
---
`json:` | the resolved real path | any edit; a symlinked file is watched where it lives
`scan:` | every matched file | an EDIT inside a scanned page
 | every directory walked | an ADD or a DELETE, where no file is left to stat
`url:` | nothing statable | recorded as unprovable - see below
---
```

Neither half of the `scan:` record is sufficient alone, which is why both are
kept. A per-file list misses an addition; a directory list misses an edit.

The record is written by the code that **resolved** the sources, because that is
the only place that knows what a glob actually matched. Deriving it a second time
from the front matter would be a second implementation of the same question, and
the second one is the one that drifts.

## Two decisions worth stating

**A `url:` source is reported as unprovable, and the TTL branch is left alone.**
A remote source has no local mtime, so no amount of stat-ing can establish
freshness. Gating the TTL branch on the record would re-render a url-backed page
on every request and hammer the remote - so a `ttl:` is not merely compatible
with a live source, it is the only freshness mechanism such a page has. A `ttl:`
is also an explicit statement that the page may be up to N seconds stale, and it
already lets an edit to the page's own source wait out that window; making a
data-file edit jump the queue would be inconsistent in the author's favour on one
input and against it on another.

**A missing or unreadable record means re-render, not serve.** Re-rendering a
page that did not need it costs a render. Serving one that did costs the author a
silent wrong answer, and this project has spent several releases on the second
kind.

## Cost

Only pages that declare `tt_page_var` pay anything. The front-matter peek is
already performed for the TTL and is cached per (path, mtime), so a page without
sources costs one hash lookup. A page with them costs one small sequential read
plus a stat per recorded path, short-circuiting on the first one that is newer.

Measured: `render_cache_hit_ms` 92.6 ms, all ops within tolerance of the
2026-07-02 baseline.

## Verification

`t/integration/53`, driving the real processor as a CGI - the defect lives in the
interaction between the render and the cache, which a unit test of either half
would mock away.

- a `json:` edit alone re-renders the page;
- a `scan:` source tracks additions, **edits** and removals;
- a page with no declared sources is unaffected and gets no record written;
- several pages sharing one data file all refresh;
- a data file that vanishes stops the page showing it, rather than outliving it.

**The first version of this test passed against the unfixed engine**, and that is
worth recording. It aged the cached render to defeat one-second mtime resolution,
which also made the render older than its own `.md` - so the cache missed on the
ordinary rule and the page re-rendered for a reason unrelated to the fix. The
test now shifts every file back, preserving order, so the cached page is
genuinely fresh by every pre-existing rule and only the data file is newer. That
is also what really happens: an author edits data some time after the last
render.

## Related

SM251 (registry staleness, the same assumption one layer up), SM301
(`regenerate-registries`, the recovery lever for that case), and
`docs/frontmatter.md`.
