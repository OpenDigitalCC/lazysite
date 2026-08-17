---
title: "SM355 - Every 404 declares /feed.xml as its canonical URL"
subtitle: "The not-found page carries `<link rel=\"canonical\" href=\"https://<site>/feed.xml\">`, and it is served for every missing URL on the site. `/404.html` itself answers HTTP 200, so the soft 404 is indexable. Neither carries a robots directive."
brand: plain
status: filed
---

# SM355 - a canonical instruction on every missing page

## What was measured

edge 0.10.12, anonymous.

```datatable
columns: Request | Status | Canonical emitted
widths: 5.0cm | 2.0cm | X
bold: 1
tone: medium
---
`/404.html` | **200** | `https://edge.explore.lazysite.io/feed.xml`
`/no-such-page-zz` | 404 | `https://edge.explore.lazysite.io/feed.xml`
`/zz-surv/probe` (after delete) | 404 | (same page)
```

Both carry `<title>Page not found - EDGE</title>` and
`<meta name="generator" content="lazysite 0.10.12">`. Neither carries any
`<meta name="robots">`.

`audit_site` already reports `/404.html` among 6 `stale_html` entries, so
the file's staleness is detected. The canonical it carries is not.

## Why this is more than a stale file

**It is an instruction, not a mistake.** `rel="canonical"` tells a crawler
*"the authoritative URL for this content is X"*. Every missing URL on the
site currently says its authoritative version is the feed. That is the
strongest hint the page can give and it points somewhere unrelated.

**It applies to every 404, not just the leftover file.** The genuine
not-found path serves the same document, so this is not one stale artefact
in the docroot - it is the site's entire not-found response.

**`/404.html` answering 200 is a soft 404.** A page that says "Page not
found" while returning success is indexable, and search engines treat soft
404s as a quality problem in their own right. Combined with the canonical,
a crawler is told that a success-status "not found" page is canonically
the feed.

**It compounds with a feed that does not exist.** `/feed.xml` returns 404
on this instance. So the canonical points at a missing document, from a
page served for missing documents.

## The cause, established - and it is remotely influenceable

My first hypothesis was [[SM293]] step 3 and the registry cache. **That was
wrong.** The maintainer reproduced the real mechanism locally and it has
nothing to do with registries; `/feed.xml` was a coincidence of ordering.

`not_found()` caches the rendered 404 as a **file in the content root**,
and the render injects a canonical derived from `REDIRECT_URL` - the
request being served at that moment. So the **first** request to any
missing URL after a cache clear bakes its own path into the file that
every later 404 is served from.

Confirmed from outside on edge 0.10.12, on the live instance:

```datatable
columns: Step | Canonical emitted on an unrelated missing URL
widths: 7.4cm | X
bold: 1
tone: medium
---
Before | `https://edge.explore.lazysite.io/feed.xml`
`invalidate_cache {"path":"/404.html"}` | -
First missing-URL request: `/zz-CANARY-CHOSEN-BY-A-STRANGER` | -
Then request `/zz-completely-unrelated-page` | `https://edge.explore.lazysite.io/zz-CANARY-CHOSEN-BY-A-STRANGER`
```

**An anonymous visitor who is first to request a missing URL after a cache
clear chooses what every 404 on that site canonicalises to.** It is
same-origin, so this is neither an open redirect nor an injection - but
every missing page on the site then tells search engines that the real
page is a URL a stranger picked.

That also explains the HTTP 200 on `/404.html`: the cache lives in the
**served tree**, so the front end answers it directly with no engine
involvement. It is the half the engine cannot fix by cleaning its own
response.

## The fix

A not-found response should carry no `rel="canonical"` at all. There is no
canonical URL for a page that does not exist, and emitting the requested
path would be equally wrong.

Three things to settle together:

The status
: `/404.html` should not answer 200. Either it 404s like the path it
  represents, or it is not reachable as a URL.

The robots directive
: `<meta name="robots" content="noindex">` on the not-found response, so
  the page is excluded whatever else is wrong with it.

The leftover
: `audit_site` reports it as stale HTML and `lazysite-check` warns about
  docroot leftovers. If the served 404 is that stale file, the fix is
  removal plus whatever regenerates it; if the engine renders it live, the
  canonical is being computed on a path where it should be suppressed.

## Verification

- A request for a missing URL returns 404 and emits no `rel="canonical"` -
  **not the requested path either**, since that would assert that a missing
  page is the canonical version of itself.
- The cached file in the content root is rewritten when it differs, so the
  copy the front end serves directly is clean too. Cleaning only the
  engine's response leaves the served artefact wrong.
- The not-found response carries `noindex` - the only instruction that
  reaches a response the engine never sees.
- Two directions pinned so the fix cannot become worse than the bug: a
  **real** page still gets its per-host canonical ([[SM151]]) and is still
  not marked `noindex`. Stripping either would ship a large SEO regression
  as a fix.
- A 404 is still a 404 - status, content type and body - because the
  sanitiser rewrites the body.
- `/404.html` either 404s or is not served.
- `audit_site` flags a not-found page that emits a canonical. It currently
  reports the file as stale HTML and says nothing about the canonical, so
  the tool that found it does not report the thing that matters about it.

## Note on how this was found

Reported from outside as *"the stale `/404.html` carries a wrong
canonical"* - the visible half. Two corrections got from there to the
mechanism, and both are worth recording.

First, "stale" was wrong: the `generator` meta reads 0.10.12, so a current
engine produced it, which rules out an old artefact and leaves only the
explanation that something is generating it now. Second, my named cause
was wrong, and it was written as a question rather than a claim - which is
why it was checked instead of believed.

The general form is the one [[SM354]] records: fixing the half you can see
is how the other half survives. The visible half was one stale page; the
invisible half was that every 404 on the site is affected and a visitor
picks the target.

## Related

[[SM354]] (commit refs going stale in silence beside the tags that
visibly broke - the same general form), [[SM151]] (per-host canonical,
which the fix must not damage), [[SM300]] (canonical and meta handling in
the render path), [[SM248]] (a generated artefact pointing at the wrong
place), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
