---
title: "SM294 - The front door under the FastCGI pool"
subtitle: "One rule costs a process per request, because dispatch ends in exec() and exec() cannot happen inside a persistent worker. Closing that means in-process dispatch, which is a change to how the auth wrapper works."
brand: plain
status: shipped
status-note: "FILED 2026-08-13 as the one thing SM293 step 5 deliberately did not do. SHIPPED 2026-08-14 on claude/sm294-front-door-under-the-pool, in the shape described below MINUS item 2. The worker consults the routing table, answers the hot path in-process (137x) and forks for the cold path (1.11x, so never slower). Item 2 - identity as a value - is NOT done and is now SM297: it is a rewrite of the auth spine on the surface where being wrong is an authentication bypass, and this filing already said it wanted its own security review. Two things were found on the way and are recorded below: %ENV does not survive under FastCGI, and the two front doors disagree about how to refuse an engine-owned path."
---

# SM294 - one rule, without the process start

## Where SM293 left it

[[SM293]] step 5 shipped a front door: `Lazysite::FrontDoor::route()` makes every
routing decision the vhost templates used to make, and `lazysite-front.pl`
executes it. A front end can now be one rule.

It is a **CGI**, and that is a real cost: a process start per request, including
requests for images on a site that protects nothing, which the fuller templates
let the web server answer directly. So an operator currently chooses:

| Want | Take | Cost |
|---|---|---|
| One rule you can reason about | `vhost-one-rule.conf.example` | a process per request |
| Throughput | `vhost-fcgi` + the pool | a template with a dozen routing decisions in it |

That is a fair choice and both options are correct. It is not the end state.

## Why it is not simply "run the front door in the pool"

**Dispatch ends in `exec()`.** That is exactly right for a one-shot CGI and fatal
inside the pool's accept loop: `exec` replaces the process, so the worker
handling the request would cease to exist and the next request would find no
worker. The pool is not a place a dispatcher can exec from.

So the front door under the pool means **in-process dispatch**: the worker
decides the surface and then *calls* it, rather than becoming it. That is a
change to every surface's shape, and to one in particular.

## The actual blocker: the auth wrapper

`lazysite-auth.pl` validates the session cookie, sets the `X-Remote-*` trust
headers plus `LAZYSITE_AUTH_TRUSTED`, and then **execs** whatever
`LAZYSITE_PROCESSOR` names. The header hand-off IS its design - it is how the
identity crosses a process boundary.

In one process there is no boundary to cross, and the headers stop being a
mechanism and become a liability: an in-process dispatcher that sets
`$ENV{HTTP_X_REMOTE_USER}` and calls a handler has invented a forgeable channel
inside its own address space for no reason.

The better shape is obvious and is precisely why this needs its own filing:
validate the session, build an identity **value**, and pass it to the handler.
Nothing to forge, nothing to strip, and `t/lint/38`'s gate becomes unnecessary on
that path rather than merely satisfied.

But that is a rewrite of the auth spine, on the surface where being wrong is an
authentication bypass. It wants its own security review, and it should not ride
along inside a filing about front-end configuration.

## What to build

1. **An in-process surface contract.** Each surface exposes a `handle($req)`
   rather than assuming it owns the process. The processor is already closest -
   SM142 made it dual-mode with `handle_one_request()`.
2. **Identity as a value.** The auth wrapper's cookie validation becomes a
   function returning an identity; the trust headers remain the CGI-path
   mechanism and stop being used in-process.
3. **The front door as the pool's entry point**, dispatching by `route()` - the
   routing table does not change, which is the point of it being a pure function
   already.
4. **Keep the CGI front door.** It is the portable path and the dev-server path,
   and it is what makes the one-rule config work on a host with no pool.

## Care needed

- **The trust gate must not be weakened on the CGI path** while the in-process
  path is built. `t/lint/38` asserts that every surface reading a trust header
  gates it; that check stays.
- **One pool per site** is what makes site isolation process-level today
  (DOCROOT is fixed at spawn). An in-process dispatcher must not become a reason
  to share a pool between sites.
- **Measure before and after.** The claim is throughput; SM142 measured 62.2 ms
  CGI versus 0.4 ms FastCGI on a cache hit, and the same bench should say what
  this buys.

## What was actually built

Items 1, 3 and 4. **Item 2 was not**, and that is the whole shape of this
increment: the worker splits by what it can *be* rather than rewriting what it
can *call*.

- **Hot path in-process.** `denied` is answered at the door; `processor` and
  `static` fall through to `main()`, which is what this process already is. The
  routing table costs a handful of `-f` tests and no process.
- **Cold path relayed.** Another surface, or anything wrapped, is forked and
  exec'd with a pipe on fd 0 and fd 1 - descriptors, not the tied FCGI handles,
  which are Perl-level objects that do not survive `exec`. Pumped with
  `IO::Select` so a large body cannot deadlock against a large response, with a
  `RELAY_TIMEOUT` (120s) because a worker blocked on a wedged child serves
  nothing else, and `local $SIG{CHLD} = 'DEFAULT'` so FCGI::ProcManager's reaper
  does not take our exit status before `waitpid` sees it.
- **The CGI front door stays.** It is the portable path, the dev-server path, and
  what makes one-rule work on a host with no pool.

Off unless `FRONT_DOOR=1`, so an existing pool is byte-identical.

### The measurement the filing asked for

Like for like - the same URL and the same auth state in both configurations,
because comparing a cached anonymous hit against a signed-in miss invents a
regression that is not there:

| Request | CGI front door | Pooled | |
|---|---|---|---|
| anonymous page (hot path) | 71.9 ms | 0.53 ms | 137x |
| signed-in page (relayed) | 107.3 ms | 96.9 ms | 1.11x |

Never slower, and two orders of magnitude faster on nearly all traffic.

## Two things found on the way

### %ENV does not survive under FastCGI

FCGI.pm **replaces `%ENV` on every `Accept()`** with that request's parameters.
Anything the pool put in the environment at spawn is gone by the time a request
is handled. So the first cut of this work read `$ENV{LAZYSITE_FRONT_DOOR}` inside
the request loop, which is always false under the pool - the one deployment the
setting exists for - while working perfectly as a plain CGI, where `%ENV` *is*
the request.

That is the same family as [[SM285]]'s `@PROBE_EXT` and [[SM293]]'s
`%REGISTRY_CT`: fine in a one-shot process, wrong in a persistent one, and silent
in the direction where the feature simply never turns on. Different mechanism, so
it gets its own check rather than a comment: `t/lint/43` derives the settings the
pool exports **from the launcher** and asserts the processor reads each at file
scope. Deriving the list is deliberate - a list somebody must remember to edit is
a list that will be wrong, which this repo has now learned four times.

### The two front doors refuse differently

`lazysite-front.pl` answers **404** for an engine-owned path, deliberately: a 403
confirms the path exists. The processor's own guard on the same paths answers
**403**, and predates that reasoning.

Under the front door the request never reaches the processor's guard, so the
pooled door answers 404 and the two front doors agree with each other. The
standalone processor still answers 403. That divergence is left alone here
because changing it is a behaviour change to every existing deployment and has
nothing to do with the pool - but it is a real inconsistency and it is written
down rather than discovered again.

## Related

[[SM293]] (step 5, which shipped the front door and named this gap), [[SM297]]
(item 2, the auth-spine change this deliberately did not make), SM142 (the
dual-mode processor and the pool), SM139 (the pool packaging), `t/lint/38` (the
trust gate), `t/lint/42` (the two routing tables agree), `t/lint/43` (pool
settings are read at startup), `t/integration/50` (a real worker survives its own
dispatch), `docs/architecture/performance.md`.
