---
title: "SM329 - Static assets are counted as pageviews and listed as top pages"
subtitle: "Two images sit in the top fifteen pages at 124 hits each, and 524 of 5,000 sampled events are .jpg, .png, .css or .js. A request for an image is not a page view, and the day rollup is all that survives."
brand: plain
status: shipped
status-note: "SHIPPED for 0.10.12. One `_is_asset` predicate, applied at BOTH counting sites - the first-party event stream and the access log - which had carried identical page-counting logic and are the shape SM318 and SM304 were filed about. An asset stays in the event stream, where it still feeds SM213's browser-versus-bot signal; it leaves `pageviews` and `top_pages`, and is counted on its own as `asset_hits` so the subtraction is auditable rather than invisible. A silent exclusion would be its own defect, indistinguishable from traffic that never happened. The predicate matches on extension after stripping any query, because assets here are versioned `?v=<version>` and a bare-path match would have excluded nothing on a real site."
---

# SM329 - an image is not a page

## What was measured

`analyse_visitors` on edge, 0.10.10, `source: first-party`, 30-day window.

```datatable
columns: Observation | Value
widths: 8.6cm | X
bold: 1
tone: medium
---
Entries in `top_pages` that are static assets | 2 of 15
Hits attributed to those two images | 124 each, 248 together
Sampled events whose path is `.jpg`, `.png`, `.css` or `.js` | 524 of 5,000
Reported human pageviews for the window | 1,993
```

`/assets/img/msg-breaking.jpg` and `/assets/img/msg-corporate.jpg` are the
second and third most popular "pages" on the site.

## Why it matters more than a cosmetic miscount

**It displaces real pages out of the top N.** `top_pages` keeps a fixed number
of entries. Every asset in that list is a page the site owner cannot see, and
assets are numerous - a single article with four images generates four asset
hits per human page view, so they crowd out content by construction rather than
by accident.

**It inflates the headline number.** `pageviews` is the figure a customer reads
first and quotes to other people. It currently includes image and stylesheet
requests.

**The day rollup is all that survives.** `top_pages` is stored as a top-N list
per day, so a later decision to exclude assets cannot be applied retrospectively
- the excluded entries are the only record of what was displaced. Every day this
runs is a day whose page list is permanently partly wrong.

**It would corrupt everything built on top of it.** A separate brief proposes
entry pages, exit pages, session depth and path-pair trails. An image is not an
entry page, not an exit page, and not a step in a journey. Building any of those
on the current classification would produce trails that read `/ -> logo.png ->
/products`.

## What NOT to do

**Do not stop recording them.** [[SM213]]'s roadmap is explicit that static-asset
200s are *"a strong browser-vs-bot tell"*, and lists access-log ingestion as
future work partly to make them visible. Its corroboration heuristic depends on
them: *"a social referrer on a visitor whose only request is one page and no
assets is suspect"*.

They are already visible in the first-party log, ahead of that work. That is a
head start, not a problem. The signal should stay exactly where it is.

## The fix

Separate **recording** from **counting**. An asset request stays in the event
stream, where it feeds classification, and is excluded from the page-facing
aggregates:

- excluded from `pageviews`
- excluded from `top_pages`
- excluded from entry, exit, depth and trail metrics when those exist
- retained for class attribution and for the browser-versus-bot heuristic

A path is an asset if its extension is in a small list - images, stylesheets,
scripts, fonts, source maps - which is the same shape of list `noise_paths`
already uses and can sit beside it in `stats.conf`.

Two adjacent questions worth deciding at the same time rather than later:

Should the asset count be reported at its own?
: A per-day `asset_hits` counter costs one integer and makes the exclusion
  auditable. It also gives the browser-versus-bot heuristic a number to work
  from without re-reading events.

What about `/favicon.ico` and `/robots.txt`?
: Neither is a page and neither is an asset of a page. They probably belong with
  the assets rather than in `noise_paths`, since a favicon request is a strong
  browser tell and a robots fetch is a strong crawler tell.

## Verification

- `pageviews` for a day counts no request whose path is a known asset type.
- `top_pages` contains no asset paths.
- Class attribution is unchanged: a visitor fetching a page and its stylesheet
  is still classified exactly as before.
- The asset requests are still present in the event stream.
- A fixture with one page and four images reports one pageview, not five.

## Field acceptance test, outstanding

Confirmed shipped and inert on the day of the deploy: `asset_hits` is present on
all 35 index rows and reads 0, because only one day is basis 2 and it had no
asset requests yet. The field landing is what was verifiable then.

**The real test is the first FULL day counted under basis 2** - 2026-08-18 on
the instrument. `asset_hits` above zero, and no asset paths in `top_pages`.

There is a second reason it could not be tested on the day: the two asset entries
that prompted this filing were on 2026-07-18, and the reporting window slid past
that day between the two captures. The asset-bearing day is now outside the
window.

The partner agent holds the before-numbers and a register stating what a wrong
answer would mean. Whether that check is run is a release-management decision;
it is recorded here so the question survives the conversation that raised it.

# Related

[[SM213]] (the durable store, and the roadmap entry that makes assets a
classification signal), [[SM192]] (the scanner and noise classifier, whose
`noise_paths` list is the pattern to follow), [[SM140]] (first-party analytics),
and `inbox/visitor-stats-what-must-be-recorded-now-2026-08-16.md`, the review
this came from.
