---
title: "SM297 - Identity as a value, not a header"
subtitle: "The auth wrapper hands identity across an exec() as X-Remote-* headers. In one process there is no boundary to cross, and a dispatcher that sets those headers for itself has invented a forgeable channel inside its own address space."
brand: plain
status: partial
status-note: "0.16.9 (PENDING): one accessor (a value held in Lazysite::Auth::Identity) and the first surface converted - the data endpoint no longer writes its own trust headers, and a damaged session store refuses there and on every signed-in page (rulings 206, 217). The manager API in the pool still forks and execs (0.17.0, ruling 217); still BLOCKS SM614's sliding half. See the 0.16.9 section."
---

# SM297 - the last exec in the request path

## Where SM294 left it

[[SM294]] put the front door inside the FastCGI pool. The worker answers the hot
path in-process and **forks** for anything needing another surface or the auth
wrapper. Measured, that is never slower than the CGI front door it replaces and
137x faster on nearly all traffic.

What it does not do is remove the fork, because removing it means changing how
identity reaches a handler.

## Why the fork is still there

`lazysite-auth.pl` validates the session cookie, sets `X-Remote-User`,
`X-Remote-Groups`, `X-Remote-Name`, `X-Remote-Email` plus
`LAZYSITE_AUTH_TRUSTED`, and then **execs** whatever `LAZYSITE_PROCESSOR` names.
The header hand-off *is* its design: it is how an identity crosses a process
boundary, and `t/lint/38` pins that every surface reading one of those headers
gates it on the wrapper having vouched.

In one process there is no boundary to cross. An in-process dispatcher that set
`$ENV{HTTP_X_REMOTE_USER}` and then called a handler would be manufacturing a
forgeable channel inside its own address space, for nothing - and worse, it would
be manufacturing exactly the channel the trust gate exists to defend.

## What to build

Validate the session and return an **identity value**; pass it to the handler as
an argument. Nothing to forge, nothing to strip, and the trust gate becomes
unnecessary on that path rather than merely satisfied.

1. `lazysite-auth.pl`'s cookie validation becomes a function returning an
   identity (or undef), separable from the wrapper's exec.
2. Surfaces take that identity as a parameter rather than reading `%ENV`.
3. The trust headers remain **the CGI path's** mechanism, unchanged, because the
   CGI front door and every existing vhost template still rely on them.
4. The pooled front door calls handlers directly; the fork remains only for
   surfaces not yet converted.

## Why this is filed separately rather than done

Three reasons, and the first is sufficient on its own.

- **Being wrong here is an authentication bypass.** Every other item in the SM293
  and SM294 line fails towards a slower or noisier site. This one fails towards
  serving a private page to the wrong person.
- **The gain is bounded and known.** SM294 measured it: the relayed path is
  96.9 ms against 107.3 ms for the CGI door, and the requests that pay it are the
  minority on most sites. This is not a fix for something broken.
- **The one case where it bites is nameable.** [[SM223]] routes every static file
  through the wrapper on a site that has an ACL store, so such a site pays the
  relayed cost per asset. That is the same cost those requests already pay under
  CGI - so the argument for this work is a real improvement for protected sites,
  not a regression to repair.

## Care needed

- **The CGI path must not be weakened while the in-process path is built.**
  `t/lint/38` stays, and stays passing, throughout.
- **One pool per site** is what makes site isolation process-level (DOCROOT is
  fixed at spawn). An in-process dispatcher must not become an argument for
  sharing a pool between sites.
- **Measure it.** `tmp/sm294-bench.pl` already produces the comparison this
  would have to move.

## 0.16.9: one accessor, and the first surface

Built on X4 (SM1369), one surface at a time.

The accessor
: `Lazysite::Auth::Identity::request_identity` answers a value held in
  `$Lazysite::Auth::Identity::HELD` - set with `local`, so it ends with its scope -
  to any caller that names no `identity` of its own, and reads nothing from `%ENV`
  while it is held. `request_session`, which decides the value, reads the request
  (`identity => undef`). Every converted surface goes through it.

The data endpoint, converted
: `lazysite-data.pl` deleted every `X-Remote-*`, wrote the verified identity back under
  the fixed names, set the wrapper's sentinel and let its readers read them from its
  own environment - the forgeable channel inside one address space that this filing
  is about. It holds the value now and writes nothing. A session whose store cannot be
  read is refused with a 503 naming the store (ruling 206), where it was anonymous.

Pages refuse too (ruling 217)
: A page request carrying a session cookie whose store cannot be read is refused 503,
  naming the store and the repair, by the auth wrapper (CGI) and by the pool's front
  door in the worker, from request_session's fault value. No cookie, an expired cookie
  or a removed account is an ordinary signed-out visitor.

What remains, and why
: The manager API in the pool. Its relay forks, clears the identity variables, writes
  the wrapper's contract from the value and execs the API (SM1181 S4). A direct call
  needs the API to be callable in a worker, and as it stands it is a top-level script
  that answers by `exit` in eighteen places and keeps its crash-audit row and registry
  rebuild in END blocks; its session-id readers (Account, Sessions, Users) read
  `LAZYSITE_AUTH_SID`. Making it a callable is its own change: ruling 217 schedules it for
  0.17.0. Until then SM614's sliding half stays blocked here: the
  processor still cannot put a re-signed cookie on a response the wrapper execs.
: The CGI wrapper and its header contract stay, by design (point 3 above).
: The Odoo endpoint and the form handler already verify their own caller and hold it
  as a value; they write nothing.
: SM614 recorded (2026-08-27): sliding session expiry needs the auth wrapper to put a
  re-signed cookie on a response the processor emits, and the wrapper execs it, so
  SM614 shipped its settable-lifetime half and waits here.

## Related

[[SM294]] (which stopped here, on purpose), [[SM293]] (the front door),
[[SM223]] (the reason protected sites pay the relayed cost), SM142 (the pool),
`t/lint/38` (the trust gate this would render unnecessary in-process).
