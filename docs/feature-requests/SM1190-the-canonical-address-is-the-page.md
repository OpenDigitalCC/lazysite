---
id: SM1190
title: "SM1190: the canonical address is the page"
subtitle: "og:url and the canonical link name the page's scheme, host and path, with no query, escaped once."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: edge test plan 0.15.10 results, finding F-4 (inbox/2026-10-19-test-plan-01510-results.md)
area: render
status-note: "SHIPPED (0.15.11) on n679: request_uri is the path alone; page_url added; lazysite-processor/layout.pm _request_path, _canonical_page_url; t/unit/processor/144."
---

# What happened

The edge test plan walk reported:

> F-4, the canonical link carries a double-escaped query: `/zz60-form?form=zz60-f&outcome=...` renders `og:url` and `<link rel="canonical">` as `...?form=zz60-f&amp;amp;outcome=...`. That is escaped twice, so the canonical address is wrong for any page opened with a query, and it repeats whatever query a link carried.

Two faults. The `request_uri` template variable was `REDIRECT_URL` or the raw
`REQUEST_URI`, and a front end that sets only the latter hands over the query
with the path. And the stash escapes `request_uri` once already (SM796), so a
layout that writes `[% site_url | html %][% request_uri | html %]` - every
layout in the catalogue does, for both tags - escaped the ampersand a second
time. The engine's own injected canonical link (`_inject_canonical`) already
dropped the query and escaped once; a layout that writes its own is deferred
to, so the layout's wrong one won.

The page cache: the rendered page is cached as a file, with `request_uri`
baked in. On a front end that gives `REQUEST_URI` alone, the first visitor's
query was written into the cached page and served to every later visitor, so
it was a cross-visitor leak of the query. (With `REDIRECT_URL` set to the path,
which the shipped Apache and nginx wiring does, the query never entered the
variable, so no leak.) The test reproduces it on the unchanged code.

# The decision

The developer's: the canonical link and `og:url` name the PAGE - scheme, host
and path - without the request's query string. The host is the configured one
(`canonical_url`, which is the canonical domain's `site_url`, else `site_url`),
never the request's Host header; the engine already has that rule (SM151,
SM1000). A page's own declared canonical in front matter is not supported by
the engine and none was added.

# What shipped

- `request_uri` is the request path with no query or fragment. It is still
  escaped once in the stash, and it is the same value cached with the page, so
  no visitor's query reaches the cache.
- `page_url`, a new template variable: `canonical_url` (or `site_url`) plus the
  cleaned path (serving extension and `/index` dropped), escaped once, empty
  when no site address is set. A layout writes `[% page_url %]` for `og:url`
  and the canonical link. `_inject_canonical` builds from the same function
  (`_canonical_page_url`), so the two cannot differ.
- Reference and layout-briefing documentation name `page_url`.
- The catalogue's layouts build their own tags from `request_uri | html`; with
  the query gone their output is correct for any page whose path has no
  `& < > "`. They should move to `[% page_url %]` for exactly-once escaping,
  and to follow the alias canonical host. Filed to
  /srv/projects/lazysite-layouts/inbox/; nothing there was changed.

Test: t/unit/processor/144 - a page opened with `?a=1&b=2` has canonical,
`og:url` and `page_url` equal to the address without the query, with no
`&amp;amp;`; a cached hit opened with a different query carries none; a page
without a query is unchanged; run through both `REDIRECT_URL` and
`REQUEST_URI`-only front ends.
