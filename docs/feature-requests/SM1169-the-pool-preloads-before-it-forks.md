---
id: SM1169
title: "SM1169: the pool preloads before it forks, and nothing about a visitor survives in a worker"
subtitle: "The pool's parent loads the engine modules once, so a worker and every respawn start warm; a lint reads every file-scope variable of the resident code, and found three that carried data from one visitor to the next."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-18
raised-by: the release manager, wave 2 of the 0.15.9 batch (SM1082 track C1, inbox n652)
area: performance
status-note: "SHIPPED on claude/n652-the-pool-preloads-before-it-forks. Tests: t/lint/269 (the lint), t/integration/288 (three data carries fixed). C2 is not started."
---

# What was asked

SM1082 track C1 (docs/feature-requests/SM1082-every-surface-on-the-persistent-runtime.md,
"Tracks"):

> **Preload before fork** (phase 2): every engine module loaded in the pool
> parent; a lint that every file-scope variable holding request data is reset
> (the SM973 class).

Constraints kept, from the same filing: nothing added to the web server's
configuration; one pool per site; SM760's privilege separation (the launcher
drops privileges and then execs the processor, so the preload runs as the site's
user, never as root); plain CGI stays the default (the preload is in the pool's
branch only); a pooled surface carries nothing about a person from one request
to the next. The pool is not extended to any new surface (that is C2).

# What was true

`lazysite-pool.pl` execs `lazysite-processor.pl` with the listen socket on fd 0.
The processor compiles itself, then `FCGI::ProcManager` forks the workers. The
engine's `Lazysite::` modules are not loaded at compile time (ADR 0001 keeps the
CGI render path free of them): each is loaded by `_lazy_lib` on the request that
first needs it. So every worker, and every respawn (one per
`LAZYSITE_FCGI_MAX_REQUESTS` requests), paid for them on one visitor's first
request. Template's parser and Text::MultiMarkdown's rules compile on first use
too, so a worker's first page-cache MISS paid for those as well.

# What shipped

## The preload

`@POOL_PRELOAD` and `_pool_preload` (lazysite-processor/front-door.pm), called
from the pool branch of lazysite-processor.pl before `pm_manage`. They load the
eleven modules the processor and its parts name through `_lazy_lib` or `require
Lazysite::` (Identity, the three address modules, I18n, Fetch, Data::Tables,
Odoo and its Fields, Identity and Visitor) with their `use` closure, and compile
one trivial template and one trivial page of Markdown. Nothing is written and no
request has been read, so there is no person in the process to carry. A module
that will not load is logged and skipped; the worker loads it, or fails, as
before. The list is held to the code by t/lint/269: a module the processor loads
that is not on it fails there.

`Lazysite::Timing::worker_started` (found by the measurement): a worker's first
request reported `load` as the parent's age (seconds, on a respawned worker). It
is now the time since the fork.

`tools/bench-surfaces.sh --with-pool --cold-workers`: the pool recycles after
one request, so every pooled request is a freshly respawned worker's first.

## The lint (t/lint/269)

It computes the resident set (the processor, its parts, and the `Lazysite::`
modules reached from `@POOL_PRELOAD` by `use` and `require`) and reads every
file-scope `my` and `our` outside any sub (a brace-counting source scan; checked
against PPI on the processor, its parts and twenty-odd modules, where the two
agree). Each variable is a constant (literal initialiser, never assigned again:
found, not declared), or in the table as `reset` (the named reset sub is read and
must mention it), `unset` (nothing in the processor or its parts assigns it) or
`exempt` with the reason beside it. An unlisted variable fails naming file, line
and variable; a table entry matching no declaration fails too. Planted
`my %LAST_VISITOR_BY_ADDRESS;` in a module (Auth/Identity.pm) and in a part
(gates.pm): both fail; restored, it passes.

## Real offenders the lint found (data carried between visitors)

Each is in t/integration/288; each fails on the unchanged code and passes now.

- **`%PAYMENT_CONTEXT`**: the payer, the amount and the paid flag of a
  payment-gated page, never cleared. `render_content` puts it in the template
  stash of every later render in the worker, so another visitor's page could show
  the previous payer's address. Now cleared by `reset_request_state`.
- **`_scan_identity`** (the `$_scan_*` memo in sources.pm): the first visitor's
  user and groups, computed once and kept for the worker's life, so every later
  `scan:` was filtered as them: a page listing could show a later anonymous
  visitor what the first signed-in visitor could see, or hide what they could not.
  Reachable under `proxy_identity`, where identity reaches the pool. Now cleared
  by `_reset_scan_identity`, called from `reset_request_state`.
- **`$RESPONSE_LANG`**: the last rendered page's language, sent as
  `Content-Language` on a request that rendered nothing. Now reset to `en`.

`$RENDER_BY_ADDRESS` and `%PREVIEW_CONTEXT` came up in the scan and main() already
resets them (SM1141); 288 holds the first so it stays so.

## Left as it was, and said

`%ADDR_MEMO` (Auth::AddressScope) is keyed on the request's own address inputs
but not on `trusted_proxies`, so a change to that setting is not seen by a running
worker until it recycles. Configuration staleness, not carried data; not changed
here.

# Evidence (shared host: load average 16-18 on 8 CPUs, so read the ratios)

`tools/bench-surfaces.sh` pins itself to one CPU at nice 19. A page-cache miss as
a respawned worker's first request (`--with-pool --cold-workers`, n=30, three
runs each, base tree against this branch, median ms, p90 in brackets):

```datatable
columns: Run | Before | After
widths: 2cm | 4cm | 4cm
---
1 | 119.8 (202) | 48.1 (77)
2 | 116.0 (160) | 38.1 (57)
3 | 108.1 (193) | 50.7 (103)
```

A warm worker's cache miss is 12.6 ms, a warm hit 1.1 ms. The `identity` phase of
a respawned worker's first request fell from 7.5-16 ms to 0.3 ms in every run.
A cache HIT as a respawned worker's first request is inside the noise (13.6 and
13.0 ms). The preload costs the parent once: about 60-140 ms of CPU for the
modules and 35-75 ms for the template and Markdown warm-up (pinned, nice 19, at
that load). Relayed surfaces (signed-in, manager, MCP, data, Odoo) run in a child
process and are unchanged by this; their figures moved only with the load.

# Related

[[SM1082]], [[SM973]], [[SM142]], [[SM139]], [[SM1144]], [[SM294]], [[SM1141]].
