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
status-note: "PLAN revised 2026-10-17 with the Odoo endpoint measurement: T0 measure, Q1-Q5 quick wins, then C1 preload, C2 identity in-process (own review), C3 a process model per surface; R1-R4 ruled as proposed 2026-10-17; C3's Odoo part waits for OOM's resident design. Earlier a PROPOSAL: measure, preload, SM297, per-surface isolation, work out of the request."
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

# Plan, revised 2026-10-17

The release manager, 2026-10-17: "check inbox re performance, make a plan to
get this addressed". The sites agent's measurement
(`lazysite/inbox/2026-10-17-the-200-ms-before-an-odoo-call-starts.md`, taken in
the OOM Lab, medians of seven) is the first figure for a surface this filing
covers: an Odoo read is about **550 ms**, of which about **200 ms is lazysite
starting two programs** (the auth wrapper, then the endpoint, each compiling
and loading its modules), about **240 ms is OOM starting up** (filed to OOM: a
lazy registry and a resident client) and **50-90 ms is Odoo**. A pooled
install does not help today: the front door relays the endpoint with fork and
exec, like every surface that carries an identity.

**What changed since 2026-10-14 that makes phase 3 smaller.** SM1129-SM1133
(SM1128 phase 1) put the proxy-trust decision in one function
(`Lazysite::Util::proxy_identity`) and the reading of identity headers in one
module (`Lazysite::Auth::Identity::request_identity`), and SM411 already put
cookie verification in one chain (`Lazysite::Auth::Session`). In-process
identity is now "call the verifier the wrapper calls, and pass the result as a
value", not a rewrite of the spine.

## Tracks, in order

```datatable
columns: Ref | Work | Size | Effect | Depends
widths: 1.1cm | X | 1.2cm | 3.6cm | 2cm
---
T0 | **Measure.** `Server-Timing` per phase (config, identity, load, render, call, write) on every surface and in the access log; a bench per surface under CGI and the pool, run in a constrained container or pinned with taskset (never extra load on the shared host); the request mix from the visitor logs; the fleet's pool status (which sites run the pool) from `lazysite check`. | S | the before figures, and a regression gate | -
Q1 | **Who is signed in, on `?csrf=1`** (P3): the endpoint returns the identity cookie's display name, so a page stops making an Odoo call only to show a name. | S | one Odoo call less per page view | -
Q2 | **A batch call** (P2): `POST {calls:[...]}` on the Odoo endpoint, each call checked and recorded as now. | S-M | N reads pay start-up once | -
Q3 | **Lighter cold path** (P4): load `Lazysite::Odoo` and OOM only on the branches that call Odoo (`?csrf=1` and sign-out do not). | S | 50-100 ms on those branches | -
Q4 | **The dev server forks per connection** (P5, dev only), so parallel reads stop queuing and the lab's timings are real. | S | honest measurements | -
Q5 | **Registry rebuild out of the request** (phase 5): the scheduler rebuilds after a write; a stale registry is served meanwhile. | S-M | removes 1.5-3 s from an unlucky request | -
C1 | **Preload before fork** (phase 2): every engine module loaded in the pool parent; a lint that every file-scope variable holding request data is reset (the SM973 class). | S-M | cheaper workers and respawns; the precondition for C2-C3 | T0
C2 | **Identity in-process** (phase 3, SM297): the front door verifies the session with `Lazysite::Auth::Session` and passes the identity as a value to the surface it dispatches, with no exec of the auth wrapper; headers are never read for identity in-process except through `request_identity` under `proxy_identity`. Its own security review and its own release. | M-L | signed-in pages, the manager, MCP, DAV, data, forms and the Odoo endpoint all reach the pooled path | C1
C3 | **A process model per surface** (phase 4): each surface declares `pool` (persistent, reset between requests) or `warm-fork` (forked per request from the preloaded parent, 1-3 ms, fresh state). Credential-bearing surfaces (auth, the manager, the Odoo sign-in) take `warm-fork`; the Odoo read path takes `pool`, so it keeps `Lazysite::Odoo`, its bindings and - once OOM keeps its clients - a warm Odoo connection (P1). Per-request state reset and worker recycling as the pool's; CGI stays the fallback. | M | an Odoo read toward Odoo's own 50-90 ms; every identity request near the pooled 1-3 ms | C2, OOM's resident client for the last part
X1 | **OOM's start-up** (~240 ms): a lazy registry and a resident client, filed to OOM by the sites agent. Not lazysite's to build; C3 uses it when it exists. | - | the largest single cost after C3 | OOM
```

Q1-Q5 are independent of each other and of the C track, so they can go now
as one batch; T0 goes with them, so the C track has its before figures.

## Targets (to confirm against T0)

- An Odoo read from a pooled site: about 550 ms today; about 350 ms after C3;
  under 150 ms once OOM is resident (X1).
- A signed-in page on a pooled site: 97 ms today; a few milliseconds after C2.
- A page with three Odoo reads: three start-ups today; one after Q2; none
  after C3.

## Constraints kept

Everything in the earlier sections: nothing added to the web server's
configuration; one pool per site; SM760's privilege separation; plain CGI the
default and the dev-server path; C2 not started without its own ruling and
review. Added: the secrets (the Odoo connection key, the visitor and identity
secrets) readable only by the site's user, who the worker runs as; the call
record and audit line per call unchanged; a pooled surface carries nothing
about a person from one request to the next.

## Rulings needed

| Ref | Question | Proposed |
|---|---|---|
| R1 | Start T0 and Q1-Q5 now, as one batch | Yes |
| R2 | The order of the C track: C1, then C2 (its own review and release), then C3 | Yes |
| R3 | `warm-fork` for credential-bearing surfaces, the pool for the rest | Yes (the earlier open decision 3) |
| R4 | The Odoo read path as a persistent `pool` surface (so the Odoo connection stays warm), with its reset lint | Yes |
| R5 | Which fleet sites run the pool, after T0 reports them | the release manager's, per site |

## Rulings (2026-10-17)

The release manager, 2026-10-17: "oom performance evaluation underway. likely it
will have some app libs, plus a daemon with socket, so wait for this to be
confirmed. still most of this is still valid in lazysite. go through inbox items
and all rulings accepted". R1-R4 are ruled as proposed. C3's Odoo read path
waits for OOM's resident design (application libraries and a daemon on a socket)
to be confirmed; the rest of C3 and all of T0, Q1-Q5, C1 and C2 stand. R5 stays
the release manager's, per site, after T0.
