---
title: "SM248 - A secondary domain serves the primary site's sitemap, llms.txt and favicon"
subtitle: "The per-domain files are generated correctly and never reach the visitor: Apache serves the primary's copies for every host, and the engine's per-domain handler is unreachable in production."
brand: plain
status: candidate
status-note: "Reported by the sjm-claude-code site agent 2026-08-08 on harmony2050.org (0.10.0). Verified, and the ROOT CAUSE is different from the report's: the processor's SM151 P6 handler is correct - FallbackResource only routes non-existent paths, so an existing docroot file is served by Apache before the engine sees the request. Same structural cause as SM223. The fix therefore belongs in the vhost, not the processor."
---

# SM248 - a secondary domain serves the primary's docroot-root statics

## Why

On a multi-domain instance:

```
GET https://harmony2050.org/sitemap.xml
  -> <loc>https://theunited.fund/</loc>

GET https://harmony2050.org/llms.txt
  -> "# UNITED"
```

Neither reflects the domain that was asked. `favicon.ico` on the secondary host
is byte-identical to the primary's, so the browser tab shows the wrong
organisation's emblem.

The generated files are **correct**. Under the domain's content root,
`/sites/harmony2050.org/sitemap.xml` carries the right `<loc>` entries and
`llms.txt` is titled for the right organisation. `update_registries` resolved the
content root, scanned that subtree and wrote per-host files properly. Only the
serving is wrong.

The impact is machine-facing and invisible from the content side: a crawler is
told the site is a different organisation, an AI client reading `llms.txt` is told
the same, and the site owner's own agent produced correct files and **cannot see
or fix the problem**.

## What is actually true

The report attributes this to docroot-root statics resolving against `$DOCROOT`
rather than the host's `content_root`. The processor's code is in fact correct;
it simply never runs.

`lazysite-processor.pl` carries the SM151 P6 handler, gated on
`$croot ne $DOCROOT`, which serves a content-rooted host's own static files. Its
own comment names the catch:

> Production fronts serve these directly or via a per-host vhost rewrite; this is
> the portable net (dev server / FallbackResource-only fronts).

And the vhost:

```apache
FallbackResource /cgi-bin/lazysite-auth.pl
```

**`FallbackResource` only routes paths that do not exist.** `$DOCROOT/sitemap.xml`
exists - it is the primary's - so Apache serves it directly, for every Host, and
the processor is never invoked. The per-domain handler is unreachable in
production and works only on the dev server, which is exactly where it was
tested.

This is the same structural cause as SM223 (static files bypass the auth gate):
**Apache serves an existing docroot file before the engine can apply per-host
logic.** The vhost already contains a precedent fix for the same shape - a
`<FilesMatch "\.brief$">` deny, added because `FallbackResource` would otherwise
serve a `.brief` raw.

## What to change

The fix belongs in the vhost generators
(`tools/lazysite-{apache,nginx}-vhost.pl`), not the processor.

For a host with its own `content_root`, docroot-root static requests must resolve
against that content root first. Two shapes:

- **A per-host rewrite** mapping `/sitemap.xml` and friends to
  `<content_root>/sitemap.xml` when the requesting Host has one. Precise, and it
  means the vhost must be regenerated when a domain gains a content root.
- **Route these specific paths through the processor unconditionally**, letting
  the existing SM151 P6 handler do the work it was written for. Simpler and
  self-maintaining; the cost is a CGI invocation for files that are currently
  served statically, on paths that are not hot.

The second is likely right for the SEO artefacts (`sitemap.xml`, `llms.txt`,
`robots.txt`, the feeds), which are fetched rarely. The first suits assets like
`favicon.ico`, which are fetched constantly.

**A host with no content root of its own must keep inheriting the primary's
files** - that is the SM110 chrome-only alias case and it is correct today.

## Also affected, per the report

`favicon.ico` is confirmed. Worth checking on the same path before deciding
scope: `robots.txt`, `feed.rss` / `feed.atom`, `404.html` / `402.html`, and the
search index and results pages.

## The wider point

This is the third SM151 edge found on one instance in two days - SM241
(`domain-set` did not mirror theme assets), SM242 (the layouts briefing had no
multi-domain section) and now this. The reporting agent suggests a pass over
multi-domain as a group rather than three separate fixes, and that is worth
taking seriously: two of the three now share one root cause in the vhost, which
no amount of per-symptom fixing would have surfaced.

## Verification

- A content-rooted secondary domain serves its OWN sitemap, llms.txt and feeds.
- A chrome-only alias with no content root still inherits the primary's.
- The primary site is unchanged.
- Whatever the mechanism, it works on a production Apache front, not only on the
  dev server - which is the specific failure this request exists to correct.

## Not in scope

- Registry generation, which is correct.
- SM223's auth question, which shares the cause but is a different decision.
