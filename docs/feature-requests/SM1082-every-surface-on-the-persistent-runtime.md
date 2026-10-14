---
id: SM1082
title: "SM1082: every surface on the persistent runtime, and the work moved out of the request"
subtitle: "The FastCGI pool makes an anonymous cached page about 100 times faster than CGI. Everything that carries an identity still starts a process per request. This filing proposes how to close that, and what else would improve responsiveness."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-14
raised-by: the release manager, 2026-10-14 ("we explored using forking process before ... both have happened. propose to me how we might now implement this, to improve performance")
area: performance
status-note: "PROPOSAL, nothing built, nothing measured for it yet. Filed so it can be revisited: phase 0 (measure, and find which fleet sites run the pool), then preload before fork, then SM297 (identity as a value, its own security review), then per-surface isolation, then work out of the request. The release manager asked to revisit it shortly."
---

# The request

The release manager, 2026-10-14: "we explored using forking process before, but
that meant a daemon and more modular construction. both have happened. propose to
me how we might now implement this, to improve performance. what changes would be
made, and what else to increase responsiveness."

This filing records the proposal made in reply. It changes no code. It is
revisited by the release manager before anything is built.

# What exists, and what it measured

From docs/architecture/performance.md, SM142, SM294, SM297, SM693 and SM973. The
figures are the filings' own, taken on their reference host; none was
re-measured for this filing.

| Path | CGI | Pooled |
| --- | --- | --- |
| Anonymous cached page | 62 to 72 ms | 0.4 to 0.5 ms |
| Signed-in page (relayed through a fork and the auth wrapper) | 107 ms | 97 ms |
| Manager, control API, MCP, DAV, data endpoint, forms, /account | 60 to 100 ms | not pooled |

- **The pool** is a FastCGI prefork: `tools/lazysite-pool.pl` binds the socket,
  drops privileges and execs the processor, which runs `FCGI::ProcManager`
  (`LAZYSITE_FCGI_WORKERS`, recycle after `LAZYSITE_FCGI_MAX_REQUESTS`, default
  500). One pool per site; DOCROOT is fixed at spawn.
- **The front door in the pool** (SM294, `FRONT_DOOR=1`) answers a page, a miss,
  a content static or a denial in-process, and relays anything else to a forked
  child with a timeout.
- **The floor** (SM693): about 70 ms of a cache hit is spent before any content
  is rendered. Module loading is about 50 ms of it. The whole render pipeline is
  about 24 ms.
- **The remaining exec** is the auth wrapper. `lazysite-auth.pl` validates the
  cookie, sets `X-Remote-User`, `X-Remote-Groups`, `X-Remote-Name`,
  `X-Remote-Email` and `LAZYSITE_AUTH_TRUSTED`, and then execs the processor.
  SM297 ("identity as a value") is the filed, unstarted change; its own status
  note says it rewrites the auth spine and wants its own security review and
  release.
- **A known cost of persistence** (SM973): a pooled worker kept serving a file
  after it was protected, because one cache was never reset between requests.
  Fixed in 0.15.3. The class remains possible for any file-scope variable.

So anonymous traffic on a pooled site is solved. A request that carries an
identity, and every non-page surface, still pays a process.

# To find out first

1. **Which fleet sites run the pool.** On sites.lazysite.io pages answer in 1.1
   to 1.9 s against 0.24 s for a theme asset, which reads as plain CGI. If most
   sites are not pooled, enabling the pool is the largest available gain and
   needs no engine work. This is a question for the sites agent and an operator
   row if the answer is a host change.
2. **Resident memory per worker.** Seventeen sites with two workers each is a
   large memory bill, and the host ran short during the 0.15.5 gate on
   2026-10-13. Measure before multiplying workers.
3. **Whether the pool preloads before it forks.** The processor's own modules
   load at compile time, before `FCGI::ProcManager` forks. The manager, auth,
   data and Odoo modules load lazily, so once per worker, after the fork. This is
   read from the code, not measured.

# The proposal

Phases, in order. Sizes are estimates.

1. **Measure (S).** Per-phase timings in a `Server-Timing` header and in the
   access log (configuration, auth, render, write). Benchmark each surface under
   CGI and under the pool, with resident memory per worker. Take the request mix
   from the real visitor logs, so the work follows the traffic.
2. **Preload before fork (S to M).** Load every engine module in the pool's
   parent before it forks, so workers share the pages and a respawn is cheap. Add
   a lint that every file-scope variable holding request data is registered for
   reset, so an SM973 cannot recur.
3. **Identity as a value, SM297 (L, own security review).** Resolve the session
   in-process. The front door dispatches to handlers directly, with no exec of
   the auth wrapper. This brings signed-in pages, the manager, MCP, DAV and the
   data endpoint onto the pooled path. The risk is the trust boundary: in-process
   identity must come from the verified cookie only, never from a request header,
   or a supplied `X-Remote-User` becomes a forgeable channel inside the address
   space. Lint 38's rule that a surface reads those headers only when the wrapper
   has vouched is what this replaces, so its replacement needs its own tests and
   its own release.
4. **Per-surface isolation (M).** A declared property on each surface: `pool`
   (a persistent worker reused across requests) or `warm-fork` (a preloaded
   parent that forks per request, about 1 to 3 ms, fresh state every time).
   Surfaces that carry credentials or sessions (manager, auth, the Odoo
   sign-in) take warm-fork. The anonymous hot path keeps the persistent worker.
5. **Work out of the request (S to M).** A registry rebuild after content
   changes takes 1.5 to 3 s on the first request that finds it stale (SM1069
   measurement, 1,800-rule fixture). Move it to the scheduler, serve the old
   registry meanwhile, and rebuild after a write. SM666 names the class: "the
   work attaches itself to whoever is unlucky".

# Other responsiveness, independent of the process model

- `ETag` and 304 on rendered pages, so a revalidation costs about 0.5 ms pooled.
  SM1068 made pages under write-only rules cacheable, so more pages benefit.
- Precompressed copies of cached pages, served with `Content-Encoding`.
- Stale-while-revalidate headers on anonymous pages.
- Manager page weight: 307 inline styles were counted by lint output. A separate
  measurement.
- For a CGI request the rule store is still decoded once. The release manager
  ruled on 2026-10-13 ("No, leave as is", SM1068) against an on-disk decoded
  copy, so the persistent worker is what removes that cost.

# Constraints carried

- Nothing is added to the web server's configuration (the standing
  self-sufficiency rule): all of this lives in the engine and its pool.
- One pool per site stays, and so does the privilege separation (SM760).
- Plain CGI remains the default and the dev-server path.
- Phase 3 is not started without its own ruling and review.

# Decisions the release manager has not yet taken

1. Whether to start phase 0 and the fleet question now.
2. Whether phase 3 (SM297) is the next large item, or whether the pool being
   enabled across the fleet comes first.
3. Whether `warm-fork` is wanted at all, or the pool alone with a stricter reset
   lint.

# What was not verified

The numbers above are the earlier filings'. Which sites are pooled, the
resident memory per worker, whether the manager modules load before or after the
fork, and the cost of a warm fork on this host are all open until phase 0.
