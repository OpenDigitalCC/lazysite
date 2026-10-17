---
id: SM1144
title: "SM1144: a request says where its time went"
subtitle: "Every surface the engine answers reports its phases in a Server-Timing header and, for the processor, in the access log. A bench reads them per surface under CGI and the pool, and `lazysite check` reports the pool. SM1082 track T0."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the release manager, 2026-10-17 (SM1082 R1 ruled as proposed - "all rulings accepted")
area: performance
status-note: "SHIPPED on n640: lib/Lazysite/Timing.pm, tools/bench-surfaces.sh and .pl, tools/lazysite-check.pl report_pool_status; t/unit/lib/204, t/integration/287, t/unit/odoo/50, t/tools/170, t/tools/171."
---

# What happened

SM1082 (every surface on the persistent runtime) cites its own track T0:
"**Measure.** `Server-Timing` per phase (config, identity, load, render, call,
write) on every surface and in the access log; a bench per surface under CGI and
the pool, run in a constrained container or pinned with taskset (never extra load
on the shared host); the request mix from the visitor logs; the fleet's pool
status (which sites run the pool) from `lazysite check`." It was ruled with the
rest of R1 on 2026-10-17: the later tracks (Q1-Q5, then C1-C3) are sized against
figures nobody had.

The sites agent's measurement of an Odoo read (2026-10-17, the OOM Lab, medians of
seven, load average about 11) is the only per-surface figure there is: about
550 ms, of which about 200 ms is lazysite starting two programs, about 240 ms is
OOM starting up and 50-90 ms is Odoo. It was taken from outside, with a script of
the lab's own, and it could not say which of lazysite's 200 ms was module
loading, which was the account check, and which was the endpoint's own work.
SM693 had measured "the floor" of a cache hit once (about 70 ms before any content
is rendered) and nothing had measured the rest.

# What shipped

## One helper

`Lazysite::Timing` (lib/Lazysite/Timing.pm). It was found by looking: no timing
helper existed (`tools/bench.pl` times operations from outside, and the processor's
`log_event` carries no durations). It depends on `Time::HiRes` and nothing of
ours, because the processor's render path loads no `Lazysite::` module (ADR 0001):
the processor loads this one file, by the lib search every surface uses, when it
can find it, and serves exactly as before when it cannot.

It is a stopwatch: `to($phase)` closes the phase in progress and opens the next,
so a surface marks where a phase starts and nothing is counted twice. `add()`
takes a figure measured elsewhere. State is reset by `begin()`, so a pooled
worker carries nothing between requests.

## The phases

```datatable
columns: Phase | What it is
widths: 2.2cm | X
---
config | Reading lazysite.conf and the request.
identity | The auth wrapper (its whole time, handed across the exec), or the session, token or Basic check in the surface itself.
load | Module loading: from the helper being loaded to the first engine code, so the compile and `use` of everything a program loads up front. Only the request that started a process has one. A program that loads modules inside its handler (the Odoo endpoint does) counts that as load too.
render | Producing the answer: a page, a listing, a JSON body. A static the engine serves.
call | An Odoo call (a read, a confirm, a sign-in, a sign-out, an identity refresh) made for the request.
write | Persisting: the page cache a render writes, a row, a file over WebDAV, an action that mutates, an MCP tool that is not a read.
```

Only phases that happened appear. A phase nothing entered is absent, never zero,
so a zero in a report means "too quick to show".

## Where it is on the response

A `Server-Timing` header (`config;dur=1.20, identity;dur=0.30, render;dur=3.40`,
milliseconds) on: the processor's pages, its 404 and other refusals through
`output_page`, and the content statics (200, 206, 304, 416); the manager API
(`respond` and `_emit_json`); MCP (`send_json` and the status, 401 and 503
answers); the data endpoint; the Odoo endpoint; WebDAV (`send_response` and the
streaming GET). The auth wrapper hands its time to the surface it execs through
`LAZYSITE_TIMING_HANDOVER` (a known phase and a plain number only; the next
`begin()` takes it out of the environment), so the surface reports the wrapper's
`identity` and both programs' `load`. A response the pool relays keeps the child's
header.

Not covered, said here rather than left to be found: a streamed download from the
manager API (`stream_bytes`) and the wrapper's own direct answers (its login
redirects), which carry none. They are not the surfaces SM1082 is about.

## Who is shown it (decided)

A Server-Timing header is readable by anyone who can read the response, and a phase
duration leaks a little (that a page was a cache hit, how long an account check
took). So it is **off for anonymous visitors by default**: shown to a verified
operator, and when `server_timing: on` is in lazysite.conf, and to nobody else. An
operator is:

- the processor: a signed-in account `_is_manager` accepts (the `ui` capability
  from a group, or any account on a site where no group grants it, the admin bar's
  own test);
- the manager API, MCP and WebDAV: any caller that authenticated, because those
  surfaces are the operators' own and refuse the rest;
- the data and Odoo endpoints: a verified session whose account holds `ui`.

A refused credential is shown nothing. `server_timing` is read from the site's
lazysite.conf only; a per-domain alias override is not applied. It is not on the
manager's Config page (a measurement switch, not a setting a site owner chooses
by looking at a form); it is a conf line.

## The access log

The processor's access record gains a `tm` object, appended after the existing
fields: `{"t":...,"s":200,...,"h":"...","tm":{"config":0.5,"render":0.7}}`. A reader
of the older fields sees the line it always saw. It is recorded whatever the
`server_timing` setting says, because the log is the operator's own file. The
other surfaces write no access log (they write the audit trail, which records
material actions only), so their phases are on the response alone.

## The bench

`tools/bench-surfaces.sh` pins itself to one CPU at nice 19 (and `ionice -c3`
where there is one) and then runs `tools/bench-surfaces.pl`, which refuses to run
if it was not started that way, and a host with no `taskset` is refused rather than
measured unpinned. It sends its requests one at a time, with no parallelism, and
reports the median and the 90th percentile of every phase, of the whole request,
and of what no phase accounts for (`other`: the interpreter starting, the response
leaving, the process exiting). The default N is 3, so a dry run is a test.

- With no `--docroot` it builds a throwaway site (an operator, a connector with
  the `mcp` capability, a WebDAV publisher, an SQLite table when the modules are
  there) and removes it at the end. It measures `page`, `page-signed-in`
  (wrapper then processor), `manager` (wrapper then API), `mcp`, `data`, `odoo`
  (wrapper then endpoint, as the dev server and the rewrite run it), `odoo-direct`
  and `dav`. The Odoo figures are the `?csrf=1` request: the harness has no OOM and
  so no `call` phase; `t/unit/odoo/50` shows the phase with OOM's fake Odoo.
- `--with-pool` starts a ONE-worker front-door pool of its own on that site, in the
  same unprivileged way `tools/lazysite-pool.pl` runs when started by hand, measures
  the same surfaces through it, and stops it.
- `--docroot D --socket S` measures an existing pooled site as a client would, the
  surfaces an anonymous request reaches, and requires `server_timing: on` in its
  conf (it will not change the conf).
- `--json` for a machine.

## `lazysite check`

One line, always: `pool: no (plain CGI)`, `pool: yes, N workers (<instance>.conf)`
(the conf names this docroot and its socket is there), or `pool: configured, N
workers (...), but its socket ... is not there` as a WARN with the unit to start.
`WORKERS=` unset reads as the launcher's default of 2. The pools directory is
`LAZYSITE_POOLS_DIR` or `/etc/lazysite/pools`. R5 (which fleet sites run the pool)
reads this from the deploy reports.

## The first figures, from this host

Taken 2026-10-17 on the development host with `tools/bench-surfaces.sh --n 15`,
CGI path, the throwaway site, one CPU (`taskset -c 0`), nice 19. **The host's load
average was about 30 on 8 CPUs for the run and the bench was pinned to a busy CPU
at the lowest priority, so every figure is inflated several times over the
reference host's (62 to 72 ms for a cached page).** They are for the shape, not
the level; the level needs a quiet host.

```datatable
columns: Surface | Total med/p90 | config | identity | load | render | other
widths: 3cm | 2.6cm | 1.6cm | 1.8cm | 2cm | 1.6cm | 2cm
---
page (processor, cached) | 406 / 636 | 0.5 | 18.1 | 306 | 0.7 | 54
page-signed-in (wrapper, processor) | 817 / 1043 | 0.5 | 24.7 | 430 | 84.7 | 128
odoo (wrapper, endpoint, `?csrf=1`) | 510 / 1028 | 0.0 | 7.4 | 308 | 5.6 | 179
odoo-direct (endpoint, `?csrf=1`) | 314 / 647 | 0.0 | 2.0 | 220 | 2.0 | 79
```

What they say, with the caveat above: on both CGI paths the largest phase is
`load`, module loading, by a wide margin (about three quarters of a cached page and
of an Odoo token request); the account check and the work itself are small. The
wrapper's contribution to the Odoo path is the gap between `odoo` and
`odoo-direct`: about 200 ms here, which is the sites agent's "two programs" finding
read off a response instead of inferred. Through the one-worker pool, in a shorter
run on the same host, an anonymous cached page took a median of 6.4 ms against 320
for the CGI (no `load`, no process start), and the surfaces that need the wrapper
or are not pages cost what they cost under CGI, because the front door relays them
by fork and exec - the SM1082 plan's premise, now visible.

## Not done here

The request mix from the visitor logs (the third clause of T0) is not part of
this: the `tm` field now lets the access log carry phases, but the mix needs the
log's volume on a real site and is a separate read. The Odoo `call` figure needs a
site with OOM and a binding; the harness measures the endpoint's own start-up.

Tests: t/unit/lib/204 (the helper), t/integration/287 (the header on every
surface, present when enabled and absent when not, and the access log field),
t/unit/odoo/50 (the `call` phase), t/tools/170 (the bench and its constraint),
t/tools/171 (check's pool line).
