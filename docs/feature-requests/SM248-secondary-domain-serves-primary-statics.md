---
title: "SM248 - A secondary domain serves the primary site's sitemap, llms.txt and favicon"
subtitle: "The per-domain files are generated correctly and never reach the visitor: Apache serves the primary's copies for every host, and the engine's per-domain handler is unreachable in production."
brand: plain
status: shipped
status-note: "CLOSED 2026-08-11. BOTH halves shipped - the registry routing (0.10.4) and the favicon/site-identity half (0.10.5). What remained in the note was never development work: it is the operator action of re-rendering existing vhosts, which every release since has needed and which is now itself covered by [[SM270]] (a re-render resets the docroot permissions). Nothing here is outstanding. ORIGINAL: PARTIAL 2026-08-08: the REGISTRY half is fixed - all four shipped vhost templates route sitemap.xml, llms.txt, robots.txt and the feeds to the engine unconditionally, pinned by t/lint/28. An operator action is needed on EXISTING sites: templates apply at install time, so a deployed vhost keeps the defect until regenerated. The FAVICON half is DONE 2026-08-09 (unreleased on main), and NOT by routing icons to the engine - that was rejected on cost, since a crawler fetches a sitemap rarely and every visitor fetches an icon. The generated per-host rewrites (`lazysite-*-vhost rewrites`) already serve a domain's OWN icon from its content root; what was missing was the domain that has NONE, which fell through to the docroot and was answered with the primary's file. Those hosts now get a 404 instead: a missing favicon is unremarkable, another organisation's emblem in the browser tab is a false claim about whose site this is. Covers favicon.ico, favicon.svg, both apple-touch icons and site.webmanifest. A host with no content root of its own is untouched and still inherits (the SM110 chrome-only alias case). Operator action: run the `rewrites` verb and paste - now documented under 'Multi-domain statics' in docs/reference/webserver-wiring.md, which it was not before. The rest of the cluster: SM253 and SM249 shipped, SM223 shipped (unreleased). Reported by the sjm-claude-code site agent 2026-08-08 on harmony2050.org (0.10.0). Verified, and the ROOT CAUSE is different from the report's: the processor's SM151 P6 handler is correct - FallbackResource only routes non-existent paths, so an existing docroot file is served by Apache before the engine sees the request. Same structural cause as SM223. The fix therefore belongs in the vhost, not the processor."
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

## Narrowing, 2026-08-08 (site agent, testing 0.10.3)

**The registry half could not be reproduced on 0.10.3.** It still reproduces on
theunited.fund (0.10.0), where `harmony2050.org/llms.txt` returns `# UNITED`. On
`edge2.explore.lazysite.io` the domain serves its own `llms.txt` and `sitemap.xml`.

That result proves less than it looks, and the reporter says so: edge's PRIMARY
has no `llms.txt` or `sitemap.xml` at all (both 404), so there was nothing for
the secondary to fall through TO. **Establish which of "already fixed" and "edge
does not exercise the path" is true before doing any work** - if it is already
fixed, the remaining action is only that 0.10.0 sites carry it until they
upgrade. The clean confirmation needs a 0.10.3 instance whose primary DOES have
registries and whose secondary has its own content root.

**The favicon half stands unchanged**, and is the easier reproduction: a
secondary domain with no favicon of its own serves the primary's byte-for-byte.

### A lookalike that is NOT this defect

`fr|th|ru.providers.explore.lazysite.io` serve sitemaps listing the PARENT's
URLs, which looks exactly like this bug. It is not: the file is wrong on disk as
well (fetched over WebDAV from the domain's own content root), and generation was
correct - those domains have `site_url: "https://providers.explore.lazysite.io"`
explicitly set, `site_url_inherited: 0`. The generator used the configured value
faithfully.

That is an operator configuration matter, recorded here only so it is not
mistaken for evidence. It is a real problem for that site though: three language
domains advertising the parent's URLs are invisible to search engines as distinct
sites, and `lang_group` is empty on all three, so they are not a configured
language set either.

### The distinguishing test

For the real defect, all three must hold at once:

1. the domain's `site_url` is its own,
2. the on-disk registry under its content root is correct,
3. the served response is nonetheless the primary's file.

Anything failing (1) or (2) is a different problem.

## Shipped 2026-08-08: the registries route to the engine

Operator decision: route those paths through the processor rather than generate a
per-host rewrite for each. Self-maintaining - it works for every domain, now and
for any added later, with no vhost regeneration - and the cost is a CGI
invocation on paths crawlers fetch rather than visitors.

All four shipped vhost templates now route `/sitemap.xml`, `/llms.txt`,
`/robots.txt`, `/feed.rss` and `/feed.atom` to the engine **unconditionally**:

- Apache CGI: a `ScriptAlias` per path, which beats `FallbackResource`.
- Apache FastCGI: a `RewriteRule` with NO `-f` condition, placed before the
  cookie rule so it applies to crawler and operator traffic alike.
- nginx (both): an exact-match `location`, which beats the generic `try_files`.

`t/lint/28-registries-routed-to-engine.t` pins all four, stripping comments first
so a template cannot pass by describing the problem while still exhibiting it.

**The per-host rewrite option already existed and lost on deployability.**
`Lazysite::DomainRewrites` (SM151 P6b) generates exactly those rules and is wired
into both vhost tools as a `rewrites` verb - which PRINTS a snippet for the
operator to paste. That manual step is why the affected instances still show the
defect: the mechanism was built and never applied. Hot assets still belong to it
(favicon.ico, images and CSS stay static and fast); the registries do not.

### An operator action is required on existing sites

**This does not fix a deployed site by itself.** The templates are used at install
time, so a site installed before this release keeps its current vhost and keeps
serving the primary's registries until that vhost is regenerated or the routing
lines are added by hand. No fix at the web-server layer can avoid that.

This also settles the narrowing question above in the direction of "not
exercised": the routing was never in place on any deployed vhost, so a domain
whose primary HAS registries would have shown the defect on 0.10.3 too.

### What this does NOT close

The favicon half is untouched, and so is the rest of the cluster: **SM253** (the
404 path skips the content root and the security headers), **SM249** (theme
assets unavailable in page bodies) and **SM223** (static files bypass the auth
gate). SM223 shares the same structural cause but is a security decision about
which paths must never be served statically, not a routing tweak, and deserves to
be taken deliberately rather than folded in behind this.

## Edge, after 0.10.4: still active, and the symptom is temporarily WORSE

Validated 2026-08-09. `edge2.explore.lazysite.io/llms.txt` returns `# EDGE` while
`/sites/edge2/llms.txt` on disk correctly reads `# edge2`. That is the three-part
signature exactly: the domain has its own `site_url`, its on-disk registry is
correct, and the served response is the primary's.

The cause is the one the release notes name - **the vhost templates apply at
install time and edge has not been rebuilt.**

Worth recording because it is counter-intuitive: **the visible symptom got worse
across the upgrade.** Before 0.10.4 the primary had no `llms.txt` or `sitemap.xml`
at all, so a secondary request had nothing to fall through to and edge2 appeared
correct. 0.10.4 generates registries for the primary, which now shadow every
secondary until the vhosts are regenerated. The earlier narrowing note warned
that edge proved less than it looked for exactly this reason, and it was right.

**Operator disposition: understood, not urgent - edge will be rebuilt at some
point.** Recorded here so the next agent testing this does not file it again as a
0.10.4 regression. It is the known operator action, not a new defect.

## Verification

- A content-rooted secondary domain serves its OWN sitemap, llms.txt and feeds.
- A chrome-only alias with no content root still inherits the primary's.
- The primary site is unchanged.
- Whatever the mechanism, it works on a production Apache front, not only on the
  dev server - which is the specific failure this request exists to correct.
- The reproduction is done against an instance whose PRIMARY has registries, per
  the narrowing above - otherwise a pass proves nothing.

## Not in scope

- Registry generation, which is correct.
- SM223's auth question, which shares the cause but is a different decision.
