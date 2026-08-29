---
id: SM693
title: What the page cache actually buys, and where the remaining time is
raised: 2026-08-29
raised-by: release manager
area: performance
status: candidate
status-note: "OPEN, and the measurement changes the priorities. render_miss 93.5ms, render_cache_hit 69.8ms at the 0.11.5 cut - so the ENTIRE render pipeline (markdown, layout, nav, theme) is 23.7ms and the cache saves that much. The other 69.8ms is a floor the cache never touches: interpreter start, config resolution, auth, serving. Therefore a finer-grained cache - caching content separately and composing the rest per request - can only ever win a FRACTION of 23.7ms, and is worth building for CORRECTNESS rather than speed: a content-only cache is viewer-independent by construction, which is what [[SM688]]'s gated nav needs. The performance prize is the 69.8ms floor, which is [[SM666]]."
---

# The numbers, measured

From `tools/bench.pl` at the 0.11.5 cut (`6c39ba79`), same host, `perl v5.40.1`:

| Measurement | Value | What it contains |
| --- | --- | --- |
| `render_miss_ms` | **93.5 ms** | Cache deleted, full render |
| `render_cache_hit_ms` | **69.8 ms** | Served from cache |
| **Difference** | **23.7 ms** | The whole render pipeline |
| `verify_token_ms` | 62.7 ms | (1.49x its baseline - [[SM685]]) |
| `verify_password_ms` | 153.2 ms | (1.18x its baseline) |

Both render figures spawn the processor as a subprocess, so both include Perl
interpreter startup and full request handling. That is what makes the gap
meaningful: **the difference between them is the render, and everything else is
the floor.**

So the page cache saves 23.7 ms of a 93.5 ms request - about a quarter. Three
quarters of a cache hit is spent before any content is rendered at all.

# What is already built

| Ref | Cache | What it holds | Validity |
| --- | --- | --- | --- |
| C1 | Page render cache | The finished `.html` | mtime of source AND conf AND the nav file this host used (SM536); host-keyed per alias (SM110) |
| C2 | The refusal to cache | Nothing - deliberately | Any page with an auth level or group restriction is never read from nor written to the cache |
| C3 | Layout cache | Fetched remote layouts | Per layout |
| C4 | Registry / content-type / host / ACL-map caches | Resolution results | Per-process and on disk |

**C2 is the one worth naming**, because it already answers a question people
keep re-asking. The processor's own comment:

> A protected page is never served from - nor written to - the global .html
> cache. [...] caching it would (a) serve a stale menu that ignores a
> just-granted capability until the cache is busted [...] and (b) leak one
> user's capability-gated menu to another via the shared cache. Only
> `auth: none` (public) stays cacheable.

Both hazards of a per-viewer render are already refused. The cost is that a
gated page renders in full every time - 93.5 ms, not 69.8 ms.

# What the remaining improvements are, and what each is worth

## C5 - a content-only cache

Cache the markdown output rather than the finished page; compose layout, nav and
chrome per request.

- **Speed: nearly nothing.** It saves the markdown share of 23.7 ms and pays
  layout composition on every request. The ceiling on the whole idea is 23.7 ms
  and this takes only part of it.
- **Correctness: this is the reason to build it.** A content-only cache entry is
  viewer-independent BY CONSTRUCTION - there is nothing per-viewer in it to
  leak. That is precisely what [[SM688]]'s per-item nav visibility needs to work
  on PUBLIC pages, which are the pages C2 currently leaves cacheable and which a
  gated nav item would otherwise force out of the cache entirely.

So it should be justified as an enabler for SM688, not as a performance change,
and its filing should say so or somebody will measure it afterwards and conclude
it failed.

## C6 - fragment composition

The cached artefact becomes a shell with one clearly-bounded hole; the
viewer-dependent fragment is composed per request. Needs C5.

Feasible because **once `lazysite/auth/acls.json` exists the front end routes
requests through the CGI** rather than serving rendered HTML directly - the
Apache template sends any existing file, any clean URL with an `.html`/`.shtml`
sibling, and the site root through `lazysite-auth.pl`. The request is already in
Perl on a cache hit, so substituting into a shell is a substitution rather than
a re-render.

Two constraints to accept:

1. On a site with **no** ACLs the template serves `.html` directly. A
   shell-with-holes cannot be served that way, so either the feature requires
   auth to be configured, or those rewrite rules must route through the
   processor too.
2. **One hole, bounded.** A shell with holes everywhere is a template rendered
   per request, which is the thing the cache exists to avoid.

## C7 - the floor

69.8 ms is spent before rendering. That is interpreter startup, config
resolution, auth and serving, and no caching refinement touches any of it. It is
**three times** the entire prize available from C5 and C6 combined.

[[SM666]] (the persistent runtime) is the filing that attacks it, and
[[SM685]]'s `verify_token` at 62.7 ms sits inside it - a single credential check
costing almost as much as an entire cache-hit render.

# The recommendation

- Do **not** build C5 or C6 as performance work. Build them as part of
  [[SM688]], justified by correctness, and say so in the commit.
- Do **not** pursue per-viewer cache keys. They fragment the cache across the
  whole site for a feature used on a few items - the release manager's own
  objection, and the numbers support it: fragmenting a cache that saves 23.7 ms
  costs more than it can return.
- Do **not** pursue a PWA shell. It buys CDN-ability at the price of requiring
  JavaScript for navigation, which is the wrong trade for an engine whose output
  should read without it.
- If performance is the goal, the work is [[SM666]] and [[SM685]], not caching.

# What would make the next measurement better

`bench.pl` times the processor as a whole, so the 23.7 ms figure is a difference
of two totals rather than a measurement of the render. Before building C5 it
would be worth timing the STAGES - markdown, layout composition, nav render -
separately, because C5's value depends on which share of the 23.7 ms is
markdown. If markdown is 4 ms of it, C5 buys 4 ms and should be built purely for
SM688; if it is 20 ms, the correctness argument gains a performance one.

That measurement does not exist today and should precede the work.

# Related

[[SM688]] (the nav feature that needs C5's correctness property), [[SM666]] (the
floor), [[SM685]] (`verify_token`, inside the floor), SM536 (the nav file in the
cache validity check), SM110 (host-keyed cache slots), SM342/[[SM663]] (why
timings report rather than gate).

# Not started
