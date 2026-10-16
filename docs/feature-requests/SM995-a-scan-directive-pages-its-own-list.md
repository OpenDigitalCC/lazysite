---
id: SM995
title: "SM995: a scan directive pages its own list"
subtitle: "SM988 made the scan's 200-page cap a site setting; the release manager kept it as the ceiling and added limit= and offset= on the directive, capped by it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 P9, ruling of 2026-10-12 ("Keep, add per-scan limit=")
area: rendering
status-note: "SHIPPED (0.15.5): limit=N and offset=N on a scan: directive page the filtered, sorted list; limit= is capped by scan_limit; _total unchanged (t/unit/processor/99)."
---

# The ruling

"Keep, add per-scan limit=": keep `scan_limit` as the site ceiling; add
`limit=` and `offset=` on a scan directive, capped by it; `_total` as built
(SM988). Docs.

# What it does

`_scan_parse_modifiers` (lazysite-processor/registries.pm) strips `limit=` and
`offset=` from the pattern beside `filter=` and `sort=`. `resolve_scan` applies
them last, after the filter and the sort:

- `offset=N` drops the first N entries of the sorted list;
- `limit=N` keeps at most N, and never more than `scan_limit`.

The ceiling still decides how many pages a scan reads (the stable prefix in
file order SM988 kept), so `offset=` counts into those pages: on a 1,745-post
site, paging by date means raising `scan_limit` to cover the posts. `_total`
is as built - the pages the pattern matched that the reader may see, before
`filter=`, the cap and the paging.

A `limit=` that is not a positive whole number, or an `offset=` that is not a
whole number, is ignored and logged at WARN. Either is stripped from the
pattern whatever its value, so it can never reach the glob.

# Tests

t/unit/processor/99: the newest three; the second three; offset alone; an
offset past the end; paging after `filter=`; `limit=50` under `scan_limit: 4`
lists four; `offset=` past the ceiling lists nothing; five bad values each
list the whole result.
