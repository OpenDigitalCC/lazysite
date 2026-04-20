# Performance

## CGI execution model

lazysite runs as a CGI application. Every HTTP request spawns a fresh
`perl` process that loads its modules, reads `lazysite.conf`, resolves
the request URI, serves the page, and exits. Nothing persists between
requests at the Perl level.

Consequences:

- **No shared state** between requests. A memo written by one request
  is gone by the next. The things that do persist - the rendered
  `.html` cache files, the auth cookie's HMAC secret, the form
  rate-limit database - all live on disk.
- **Module load is the floor.** Every request pays the cost of loading
  the Perl modules it touches. The processor's static dependencies add
  up to ~50ms on the machine measured below.
- **Simple deployment.** The processor is a single script dropped into
  `cgi-bin/`. Apache or any other CGI-capable server runs it. No
  daemon, no process manager, no listening socket owned by lazysite.
- **Request isolation is free.** One request crashing cannot corrupt
  another's state, because there is no shared state to corrupt. A
  rogue page that dies in the middle of rendering affects only that
  request; the next request starts clean.

This model is the reason lazysite is tolerable on low-end shared
hosting and trivially containerisable.

## Measured baseline

Measured on Perl 5.40.1, Debian 13, Intel i7-1260P, via wall-clock
timing (`date +%s%3N`) over 10 iterations per case.

| Path | Average wall time |
|---|---:|
| Cache-hit (simple page) | 44 ms |
| Cache-miss (simple page) | 78 ms |
| Cache-miss (50-page scan) | 83 ms |

Module-loading accounts for about 50 ms of the ~58 ms total that the
processor takes to print anything - it dominates both paths. The
cache-hit path does effectively ~4-8 ms of real work on top of that
floor.

Modules loaded per request, via `%INC`:

| Path | `scalar keys %INC` |
|---:|---:|
| Cache-hit, no remote content | 67 |
| Cache-hit + remote URL touched (`fetch_url`) | 86 |

The 19-module difference is `LWP::UserAgent` and its transitive
dependencies, which are `require`d lazily and only on the fetch path.

Concurrency (10 cache-hit requests on a 6-core machine):

| Scheme | Total wall time |
|---|---:|
| Sequential | 596 ms |
| Concurrent | 164 ms |

The ~3.6x speedup under concurrent load matches what you would expect
from six CPU cores, module-load being the bottleneck. There is no
lock contention: each request has its own process and its own file
handles.

## Cache architecture

lazysite caches rendered pages as `.html` files next to their `.md`
source:

- **Cache hit.** The processor compares the mtime of `foo.md` and
  `foo.html`. If the HTML is fresh, it is served directly and the
  render pipeline is skipped entirely.
- **Cache miss.** The render pipeline runs, the HTML is written
  atomically (`foo.html.tmp.$$` then `rename`), and that file becomes
  the cache.
- **TTL.** A page may declare `ttl: N` in its front matter. If set,
  the HTML is served until mtime + N seconds, even if the source is
  newer. Useful for aggregator pages that reference `scan:` results.
- **Manual invalidation.** Delete the `.html` file, or use the manager
  cache page.
- **Caching is disabled** when the `LAZYSITE_NOCACHE` environment
  variable is set. The manager sessions always run with this on, so
  the admin bar is never baked into a cache served to anonymous
  visitors.
- **Auth- and payment-protected pages are never cached.** The
  processor detects `auth: required`, `auth_groups:`, or
  `payment: required` in front matter and skips both the cache read
  and the cache write.
- **Login and logout pages are never cached.** These pages embed
  per-request Template Toolkit variables (`query.next`) and a stale
  `.html` would serve the wrong redirect target. The processor
  recognises any URL matching `auth_redirect` (default `/login`) or
  the equivalent `/logout` as part of the auth surface and treats it
  as protected for caching purposes.

The `.html` cache is content only - there is no separate metadata
store. Content-type overrides (for `raw:` and `api:` pages) live in a
sibling `.ct` file under `lazysite/cache/ct/`.

## Optimisations in place

- `LWP::UserAgent` is `require`d lazily inside `fetch_url`,
  `fetch_oembed`, and `fetch_remote_layout`, so pages that never fetch
  remote content pay none of its cost.
- `resolve_site_vars()` is memoised per process. The conf file and
  the nav file are read once per request, not on every call site.
- `update_registries()` short-circuits when no registry templates
  exist, avoiding a scan of the docroot on every cache miss.
- Cache writes are atomic via tempfile + `rename`, eliminating the
  torn-read window.
- Template Toolkit is configured with `COMPILE_DIR` so parsed
  templates are cached on disk between process invocations.
- `EVAL_PERL => 0` is pinned on every `Template->new()` call.

## Remaining opportunities

- Consolidate the `peek_*` family (auth, payment, ttl, content_type,
  query_params). Each currently opens the source file independently;
  combining them into one parse would halve the small-page file I/O.
- Replace `Text::MultiMarkdown` with a lighter Markdown parser. MMD
  contributes ~15 ms of module load. This is a large API change and
  is not scheduled.
- Move to a persistent-process model (see FastCGI below).

## FastCGI

A persistent FastCGI wrapper is planned. Under FastCGI, the Perl
process loads its modules once at startup and then services many
requests from a loop. This amortises module-load across requests and
drops the cache-hit floor from ~44 ms to an estimated 4-8 ms.

What this requires:

- A small wrapper script that accepts FastCGI requests, rebinds the
  CGI environment per request, and calls the processor's `main()` -
  which currently runs unconditionally at script load.
- Per-request reset of the memoised state in `resolve_site_vars()`
  and `update_registries()`. The processor already exposes
  `reset_request_state()` for this; the wrapper is expected to call
  it at the start of each iteration.
- Container or VPS deployment. FastCGI is not available on most
  shared hosts.

The CGI path remains the default and supported path. FastCGI is an
opt-in optimisation for operators who can run a persistent process.
