# Performance

## CGI execution model

lazysite runs as a CGI application by default. Every HTTP request
spawns a fresh `perl` process that loads its modules, reads
`lazysite.conf`, resolves the request URI, serves the page, and exits.
Nothing persists between requests at the Perl level. (The packaged
production alternative - a persistent per-site FastCGI pool - is the
"FastCGI" section below; everything in this section describes the
default CGI mode.)

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

> Absolute wall-clock figures are environment-dependent. The numbers
> above were captured on a dedicated i7-1260P under low load. The
> module count and relative costs (cache-hit vs miss overhead, scan
> scaling) are the stable figures to compare across environments.

Module-loading accounts for about 50 ms of the ~58 ms total that the
processor takes to print anything - it dominates both paths. The
cache-hit path does effectively ~4-8 ms of real work on top of that
floor.

### Automated benchmark + regression gate

`tools/bench.pl` measures the hot paths repeatably and gates on regression:

| Op | What it times |
|---|---|
| `render_cache_hit_ms` | a processor request served from the page cache (subprocess, incl. perl startup) - the path most visitors hit |
| `render_miss_ms` | a full render (cache deleted each iteration): markdown + TT pipeline + cache write |
| `verify_token_ms` | a token credential verification (1 iteration - the partner hot path) |
| `verify_password_ms` | a password verification (100k iterations - the deliberate slow path) |

The committed baseline (`dist/config/bench-baseline.json`) is **host-relative**
and records its provenance (host, perl version, capture date); `--check` prints
it and warns on a host mismatch. Re-capture on your CI/deploy host with
`tools/bench.pl --baseline`. The gate `tools/bench.pl --check` fails on >2x the
baseline (per-op overrides possible via a `tolerances` map in the JSON) -
measured spread on a quiet host is ~3 per cent, so 2x still has ample headroom
against host variance. It runs in the release gate (`tools/release.sh`), not
the unit suite. The token-vs-password gap (token ~4x faster) is the stable
relative figure, and confirms why partners use `lzs_` tokens for DAV.

### WebDAV endpoint (SM070)

`lazysite-dav.pl` follows the same per-request CGI model. Its
auth/gate overhead is a single SHA-256 when the client uses a
generated credential (`iterations=1`); a human password costs the full
100,000 iterations per request, which is the documented reason to use
generated credentials for automation. PUT streams the body in 64 KiB
chunks (memory bounded regardless of file size). PROPFIND is the
hot path for desktop mounts (Explorer/Finder are PROPFIND-heavy): it
is O(directory entries) with one `stat` and one lock-store lookup per
entry, capped at Depth 0/1 — no recursive tree walks. Confirm the
depth-1 cost against a large directory in the close-out report.

Modules loaded per request, via `%INC`:

| Path | `scalar keys %INC` |
|---:|---:|
| Cache-hit, no remote content | 55 |
| Cache-hit + remote URL touched (`fetch_url`) | 86 |

The difference between the two rows is `LWP::UserAgent` and its
transitive dependencies, lazy-loaded only on paths that fetch
remote content.

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
- `peek_*` family consolidated into `_peek_md()`: single file read
  per cache-miss render (was up to 5 separate opens for auth,
  payment, ttl, content_type, query_params). Memoised per-request
  by path + mtime.
- `main()` decomposed into five helper functions
  (`parse_query_string`, `apply_trust_gate`, `handle_manager_path`,
  `try_serve_cache`, `is_auth_surface`). Cyclomatic complexity
  reduced from 69 to 54.
- Manager upload rejects oversize or rate-exceeding requests
  before the body is read into memory: the `CONTENT_LENGTH` gate
  and `check_upload_rate` both run before `read(STDIN, ...)` in
  `lazysite-manager-api.pl`. An attacker flooding the endpoint
  with 1 GB multipart bodies pays only the cost of parsing the
  request line and headers per request.
- Manager download streams in 64 KB `sysread`/`syswrite` chunks.
  Peak memory is bounded by the chunk size, not the file size.
- Manager zip-download builds the archive to a tempfile via
  `Archive::Zip::writeToFileNamed` then streams it in 64 KB
  chunks. `Archive::Zip` and `File::Temp` are `require`d lazily
  inside `action_file_zip_download`, so the majority of manager
  API calls (list, read, save, etc.) do not pay their load cost.
- `upload_limits()` is memoised per request: the conf file is
  parsed once, even if the size gate, rate limit, and
  per-file blocklist check all consult it within the same
  request.

## Remaining opportunities

- Replace `Text::MultiMarkdown` with a lighter Markdown parser. MMD
  contributes ~15 ms of module load. This is a large API change and
  is not scheduled. (The persistent-process model, formerly listed
  here, shipped as SM142 - see FastCGI below.)

## FastCGI

IMPLEMENTED (SM142, 2026-07-10). The processor is dual-mode: spawned with a
FastCGI listen socket on fd 0 (spawn-fcgi convention; the SM139 pool unit),
it services requests from an accept loop - modules compile once,
`handle_one_request()` runs `reset_request_state()` + the SM140 access
record per iteration, and `local %ENV` in `main()` isolates request state.
Invoked as a plain CGI it takes the single-shot path on native handles,
byte-identical to the pre-SM142 behaviour; FCGI.pm is lazy-required, so the
CGI path has no new dependency.

Measured on the reference host (mean of 50 cache-hit requests, one worker):
plain CGI 62.2 ms, FastCGI 0.4 ms - the CGI figure is almost entirely
process start, which the loop amortises away.

Knobs (set by the pool unit / spawner):

- `LAZYSITE_FCGI_WORKERS` - prefork size via FCGI::ProcManager (0/unset:
  single worker, the spawner manages processes).
- `LAZYSITE_FCGI_MAX_REQUESTS` - worker recycles after N requests (memory
  hygiene; default 500). The manager respawns it.

One pool per site: DOCROOT is fixed at spawn, so docroot-derived state is
valid for the worker's life and site isolation stays process-level. Needs
libfcgi-perl (+ libfcgi-procmanager-perl for prefork) and a web server
speaking FastCGI to the socket (Apache mod_proxy_fcgi / nginx fastcgi_pass);
the packaging shipped with SM139 (0.7.2): the `lazysite@.service` template
unit + `tools/lazysite-pool.pl` launcher and `/etc/lazysite/pools/` in
`lazysite-common`, and the `lazysite-fcgi` vhost template in
`lazysite-hestia`. The auth wrapper still execs the processor per request
(its trust-header design), so manager traffic stays on the CGI path for
now - the visitor-facing hot path is the pooled one.

The CGI path remains the default and the dev-server path. FastCGI is the
packaged production pattern, not a requirement.

## The front door under the pool

IMPLEMENTED (SM294, 2026-08-14). SM293 step 5 moved every routing decision
out of the vhost templates into `Lazysite::FrontDoor::route()`, so a front
end can be one rule - but it executed that decision from a CGI, at a process
per request. A pool worker cannot execute it the same way: dispatch there
ended in `exec()`, which replaces the process, so the worker serving the
request would cease to exist and the next request would find nothing
listening. The failure is invisible to a single request, which is answered
perfectly on the way out.

With `FRONT_DOOR=1` in the pool conf the worker consults the same routing
table and splits by what it can *be*:

- the hot path - a page, a miss, a content static, a denial - is what the
  worker already is, so it is answered in-process;
- the cold path - another surface, or anything needing the auth wrapper - is
  relayed to a forked child over a pair of pipes, with a timeout
  (`RELAY_TIMEOUT`, default 120s) so one wedged surface cannot take the
  worker, and therefore the site, down.

Measured on the reference host (mean of 60 requests, one worker, like for
like - the same URL and the same auth state in both configurations):

| Request | CGI front door | Pooled front door | |
|---|---|---|---|
| anonymous page (hot path) | 71.9 ms | **0.53 ms** | 137x |
| signed-in page (relayed) | 107.3 ms | **96.9 ms** | 1.11x |
| relay overhead alone | - | 2.5 ms | |

So the pooled front door is never the slower choice: the hot path, which is
nearly all traffic, is two orders of magnitude cheaper, and the relayed path
is marginally cheaper than the CGI door it replaces because the routing
decision itself no longer costs a process.

The limit worth stating: SM223 sends every static file to the auth wrapper
on a site that has an ACL store, so such a site pays the relayed figure for
its assets rather than the in-process one. That is the same cost those
requests already pay under CGI, not a regression - but it is the reason to
resolve identity in-process rather than across an `exec`, which is SM297.

`tmp/sm294-bench.pl` reproduces the table.
