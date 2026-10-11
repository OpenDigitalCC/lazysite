---
id: SM988
title: "SM988: a scan stopped at 200 pages without a word"
subtitle: "`scan:` read the first 200 files by name, then sorted them, and nothing said the cap was hit: a 1,745-post listing rendered short and looked complete."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, a 1,745-post site on 0.15.3, item 1); WORK-PLAN-0154 P9
area: rendering
status-note: "SHIPPED (PENDING): scan_limit in lazysite.conf sets the cap (default 200, still a stable prefix in file order); <var>_total counts the pages matched that the reader may see; a capped scan logs a warning; documented (t/unit/processor/97)."
---

# What was wrong

`_scan_collect_files` (lazysite-processor/registries.pm) took the first 200
files of a scan by name - `@files[0 .. 199]` - and `resolve_scan` then sorted
those. The cap was undocumented except as "Maximum 200 files per scan",
could not be changed, and nothing said it had been hit: `scan:/post/*.md
sort=date desc` over 1,745 posts rendered 200, the oldest by name rather
than the newest. The data tables had answered the same problem with
`<var>_total` (SM511); the scan had nothing.

# The fix

- `scan_limit:` in lazysite.conf sets how many pages a scan reads. Default
  200. Anything but a positive whole number is the default, with a warning.
- The cap is still a prefix in file-name order, so the same pages are listed
  on every render.
- `<var>_total` beside each scan list counts the pages the pattern matched
  that the reader may see, before `filter=` and before the cap. A page can
  say "showing [% posts.size %] of [% posts_total %]". Pages past the cap are
  held to the same confinement and read check as listed ones, so a gated
  page is never counted and the number says nothing about it. `filter=` is
  not applied to it: a page that was not read cannot be filtered.
- A capped scan logs a warning naming the pattern, the cap and the total.
- Documented in starter/docs/reference.md (`scan_limit`, `key_total`),
  configuration.md and features/authoring/page-scan.md.

# Open for review

The choices this made without a ruling, each easy to change:

- The key is site-wide (`scan_limit:`), not a `limit=`/`offset=` modifier on
  the directive; the plan offered either.
- `_total` is counted before `filter=`, for the reason above.
- The registries' own walk (`scan_pages`, the feed cap) is unchanged.

# Tests

t/unit/processor/97: under the cap the total is the list; over it, five of
seven are listed - the first five by name, sorted - and the total is seven;
a gated page past the cap is not counted; an unusable `scan_limit` is the
default.
