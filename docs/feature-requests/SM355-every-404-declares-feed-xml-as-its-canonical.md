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

## Probable cause, stated as a question rather than a claim

The `generator` meta says 0.10.12, so this HTML was produced by a current
engine, not left over from an old release - which makes "stale file"
insufficient as an explanation on its own. The canonical looks like it was
computed for whichever page was rendered immediately before, or for a
registry that shares the render path.

[[SM293]] step 3 moved the registries to generated-on-request with a cache
and stopped writing them into the content root, and `lazysite-check` warns
about leftovers from before that change. A 404 page carrying a *registry*
URL as its canonical sits close enough to that boundary to be worth
looking at first.

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

- A request for a missing URL returns 404 and emits no `rel="canonical"`.
- The not-found response carries `noindex`.
- `/404.html` either 404s or is not served.
- A fixture asserts the canonical is absent on a not-found render, driven
  through the engine rather than by reading the template.
- `audit_site` flags a not-found page that emits a canonical.

## Related

[[SM293]] (registries generated on request, and the docroot leftovers
`lazysite-check` warns about), [[SM248]] (a registry serving the wrong
domain's content - the precedent for a generated artefact pointing
somewhere it should not), [[SM300]] (canonical and meta handling in the
render path), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
