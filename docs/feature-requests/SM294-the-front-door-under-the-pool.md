---
title: "SM294 - The front door under the FastCGI pool"
subtitle: "One rule costs a process per request, because dispatch ends in exec() and exec() cannot happen inside a persistent worker. Closing that means in-process dispatch, which is a change to how the auth wrapper works."
brand: plain
status: candidate
status-note: "FILED 2026-08-13 as the one thing SM293 step 5 deliberately did not do. Nothing started. This is a performance and architecture item, NOT a correctness one: the one-rule front door is correct today, it is simply CGI-cost. The blocker named here is real and load-bearing - the auth wrapper's design is exec-based, and t/lint/38 pins the trust gate that design carries."
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

## Related

[[SM293]] (step 5, which shipped the front door and named this gap), SM142 (the
dual-mode processor and the pool), SM139 (the pool packaging), `t/lint/38` (the
trust gate), `docs/architecture/performance.md`.
