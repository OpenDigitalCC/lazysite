---
id: SM1398
title: "SM1398: page_url has a raw twin for JSON-LD"
subtitle: "page_url arrives HTML-escaped with no _raw twin, unlike the other page_* variables, so a layout could not put the page's address into JSON-LD through | json. page_url_raw is the same address, raw, for | json alone."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "found beside the offline kit (n770 brief, item 4), from the layouts catalogue"
area: layouts
status-note: "SHIPPED (0.16.8) on n770: render.pm adds page_url_raw beside page_url, under the SM824 contract (never in markup, only inside | json); documented in the layouts briefing and the reference. t/unit/processor/144 gains the case."
---

# What happened

SM824 gave every escaped front-matter value a `_raw` twin, so a layout can
encode one into JSON-LD with `| json` rather than entity-decode it. SM1190 added
`page_url`, escaped once for `og:url` and the canonical link, and gave it no
twin. A layout writing `"url": [% page_url | json %]` for a page whose path
holds an apostrophe put `&#39;` into a JSON string, which is wrong rather than
merely ugly.

# What was built

`page_url_raw` in the stash (lazysite-processor/render.pm), the same address
`_canonical_page_url` gives `page_url`, unescaped. The contract is SM824's: a
`_raw` value is never written into markup; the escaped name stays what every
shipped layout uses. The layouts briefing and the reference say so.

Tests: `t/unit/processor/144`, a page at `/it's`: `page_url` carries `&#39;`,
`[% page_url_raw | json %]` carries the apostrophe, and no entity reaches the
JSON.
