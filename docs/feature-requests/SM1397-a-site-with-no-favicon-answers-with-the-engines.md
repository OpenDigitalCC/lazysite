---
id: SM1397
title: "SM1397: a site with no favicon answers with the engine's"
subtitle: "A layout with no default_theme and no resolving theme emits /favicon.svg, which 404s on a fresh site. The engine now answers /favicon.ico and /favicon.svg with a small neutral mark when the site has no file, so a hand-made layout does not 404."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "found beside the offline kit (n770 brief, item 4), from the layouts catalogue"
area: front end
status-note: "SHIPPED (0.16.8) on n770: lazysite-processor/pipeline.pm _serve_favicon_fallback (an SVG and a real 16x16 ICO built in Perl), last in the pipeline before not_found; a file the site has wins, from the content root or the docroot. t/unit/processor/181."
---

# What happened

A layout that sets no `default_theme`, on a site where no theme resolves, writes
`<link rel="icon" href="/favicon.svg">` in its head - every catalogue layout
does - and a fresh site has no such file. Every page view then logs a 404 for
the icon and the browser tab shows nothing, on a site that did nothing wrong.

# What was built

`_serve_favicon_fallback` (lazysite-processor/pipeline.pm): where a request for
`/favicon.ico` or `/favicon.svg` reaches the engine - the shipped front ends hand
a path that maps to no file to it - it is answered 200 with the engine's own
mark: an SVG (a grey rounded square with a white page on it), and a real ICO
(one 16x16 entry, a 32-bit BMP with its mask, 1.1 KB, built once per process).
`Cache-Control: public, max-age=3600`; HEAD gets the headers alone.

A file the site has wins: the domain's content root, then the docroot, served
as any static is. The fallback is the last step before the 404, after every
page, alias and remap rule, so nothing a site answers is shadowed. Only the two
root paths: `/favicon.png` and `/icons/favicon.ico` are not found as before.

On a front end that serves the identity files itself and answers a missing one
with its own 404 (the nginx per-domain rewrites of `DomainRewrites`, which keep
them off the engine on purpose), nothing changes.

Tests: `t/unit/processor/181` (both paths, the ICO's structure, HEAD, the site's
file from the docroot and from a content root, nothing else invented). Fails
with the call before `not_found` reverted.
