---
id: SM1226
title: "SM1226: the Odoo endpoint runs warm-forked"
subtitle: "Every Odoo call started a perl and compiled the endpoint. A supervised parent per site now holds the compiled endpoint, and nothing else, and forks a fresh child for each request. Through the pool, an Odoo read answered by oomd went from 116 ms to 17 ms on this host."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager, 2026-10-20 (tmp/rulings-2026-10-20.md, Odoo endpoint: \"D5 - yes - i cant see why we would not want to save 200ms\"), on SM1082 R3"
area: performance
status-note: "SHIPPED (PENDING) on n711: Lazysite::WarmFork, a parent holding code only that forks a fresh child per request, runs as lazysited's odoo-endpoint service on a pooled site only; the one-rule pool and the split templates (through the pool) hand it the endpoint, the CGI the fallback. Tests t/unit/daemon/15, 16, t/integration/325, 326, t/lint/272. 116 to 17 ms."
---

# The ruling

The release manager, 2026-10-20 (tmp/rulings-2026-10-20.md, "Odoo endpoint"),
after the trade-off note: **"D5 - yes - i cant see why we would not want to save
200ms."** Run the D5 bench, and put the Odoo endpoint on warm-fork.

The note the ruling answered gave four points:

- the cost is per call, not per first connection;
- warm-fork means a preloaded parent forks a fresh child for each request, so no
  visitor's state survives into the next request;
- the parent loads code and configuration only, with no Odoo sessions, API keys or
  per-person data, and a test enforces that;
- there is one supervised parent per site, restarted on upgrade, as oomd is.

This is SM1082's R3 (2026-10-17: `warm-fork` for credential-bearing surfaces, the
shared pool for the rest) applied to the Odoo endpoint. [[SM1164]] D5 is the bench.

# What was true

- **Every Odoo call was a new perl.** Under the one-rule pool, the front door relayed
  `/cgi-bin/lazysite-odoo.pl` by fork and exec: lazysite-processor/front-door.pm,
  `_front_relay`, `exec {$^X} $^X, $program` (line 390 on the base tree). The split
  templates run the endpoint under fcgiwrap
  (installers/nginx/vhost-fcgi.conf.example, `location ~ ^/cgi-bin/...`). Plain CGI
  starts it per request by definition.
- **What a start costs.** The endpoint loads `Lazysite::Odoo` and the modules under
  it lazily, in `_engine` (lazysite-odoo.pl:319). So most of the engine's compile
  fell in the `render` phase (about 25 of the 28 ms of endpoint work), and the OOM
  client's in `call`. The rest is `load` and the interpreter's own start.
- **No warm-fork runner existed.** The only mention in lib/, the processor,
  installers/ and tools/ was a comment (front-door.pm:573, "C3 gives it warm-fork").
  SM1082, SM1169 and SM1181 plan it and none built it. So this branch builds the
  narrowest one.

# What changed

## The parent: Lazysite::WarmFork

lib/Lazysite/WarmFork.pm is a program, run by its service as
`perl -I LIB lib/Lazysite/WarmFork.pm --docroot D --script S --socket P`.

- **It loads code.** `preload` requires the endpoint script and every `Lazysite::`
  module that the endpoint and those modules name by `use` or `require`, read from
  the source. It also requires the OOM daemon client and the registry, which are
  skipped if absent. It calls no function of any of them and reads no file but
  their sources. About 70 modules are loaded, and the parent's resident memory is
  about 54 MB.
- **It never reads a request.** It binds its socket (0600, in the site's own
  `lazysite/run/`, 0700). It then loops: accept, fork, close its copy of the
  connection. The child reads the parameters, the cookies and the body off the
  connection itself.
- **The child has CGI's isolation:**
  - `%ENV` is the request's FastCGI parameters and only those.
  - The identity variables a front end could carry as parameters are deleted by
    `Lazysite::Auth::Identity::clear_identity_env`: the wrapper's sentinel, sid and
    passwordless flag, and the six trust headers. The endpoint reads none of them
    and verifies its own caller from the session cookie (SM411).
  - STDIN is the request's body. It is read off the connection only as far as the
    endpoint reads it, so the endpoint's own caps still refuse a body before it is
    read (SM1162).
  - STDOUT is collected and returned as FastCGI records.
  - The random generator is reseeded (`srand`). A fork otherwise repeats its
    siblings' `rand()`, and `Lazysite::Odoo::new_call_id` uses `rand`.
  - Timing's `load` phase starts at the fork.
  - The child then exits with `_exit`.
- **Restarted on upgrade.** Every five seconds the parent compares the files it
  loaded (inode, size, mtime). When a change has held for two seconds it stops
  listening and exits 75, and its service starts a new parent at once. Requests in
  flight finish in their own children. A parent whose service has gone (it has been
  re-parented) exits too.

## The wire: Lazysite::WarmFork::Wire

The parent speaks FastCGI's responder role, one request per connection, so a web
server could connect to it as it connects to the pool. The module holds:

- the record framing, used by both ends;
- `socket_for`, the socket's one name: `lazysite/run/odoo-endpoint.sock`, or none
  when the path is longer than a Unix socket path can be;
- the client the front door uses. It writes and reads together, so an endpoint that
  answers 413 without reading a large body does not leave either end blocked.

## The service: Lazysite::Daemon::Service::OdooEndpoint

A thin parent over the program, as `Service::Oomd` is over oomd:

- `wanted` is the gate: the site runs behind a pool (below, "Only where a front end
  uses it"), the Odoo extension is enabled, the endpoint is found, and
  the socket path fits. The daemon extension is the supervisor's own gate. With any
  of these missing, no process exists.
- The program starts in a fresh perl (exec), never as a fork of the supervisor, so
  the parent holds what it loaded and nothing the supervisor read.
- An exit of 75 is a restart, not a failure. Any other exit returns to the
  supervisor's backoff and `failed` ceiling.

The supervisor now handles its gated services (oomd and `odoo-endpoint`) by name
in one loop; until now the loop was oomd's alone.

## The front end

- **The one-rule pool.** `_front_relay` hands an unwrapped `lazysite-odoo.pl`
  request to `_front_warm`, which sends the request's parameters and its already
  bounded body to the parent's socket and passes the answer through.
  - If nothing reaches the parent (no socket, a refused connection), the CGI runs as
    before.
  - Once the parent has taken a request it is never re-run, because a write may have
    been made. A failure after that point is answered as the relay answers one: 504
    on a timeout, 500 for no output.
  - `Lazysite::WarmFork::Wire` joins `@POOL_PRELOAD`, and t/lint/269 reads it.
  - The bad-URL guard (SM1181 R5) runs before the relay, as before.
  - No template line changes: the pool templates' comments now say what happens.
- **Plain CGI and the dev server** are unchanged. They are the default and the
  fallback.
- **The split FastCGI templates (S2, ruled 2026-10-20: option a).** nginx
  `vhost-fcgi` gains `location = /cgi-bin/lazysite-odoo.pl` to the pool's socket
  (the trust headers blanked as everywhere, `fastcgi_read_timeout 150s` above the
  relay's 120 s). Apache `vhost-fcgi` and Hestia's `lazysite-fcgi.tpl` and
  `.stpl` gain `<Location "/cgi-bin/lazysite-odoo.pl">` with the pool's
  `SetHandler`, which replaces the cgi-bin's CGI handler for that one script.
  - The split templates' pool runs no front door, so the worker matches the
    endpoint by path alone (`_odoo_endpoint_request`: REDIRECT_URL, which nginx
    sets, else REQUEST_URI less its query, as Apache's proxy handler sends it) and
    `_front_odoo` treats it as the front door does: the bad-URL guard, then
    `_front_relay`, which hands it to the parent or runs the CGI. Every other
    request renders as before.
  - `tools/lazysite-pool.pl` sets `LAZYSITE_CGIBIN` (and `RELAY_TIMEOUT`) in both
    modes now, not only under `FRONT_DOOR`, so that fallback runs the site's own
    cgi-bin and honours `CGIBIN=`.
  - The web server reaches the pool's socket as before, so the parent's socket
    stays the request-path user's alone (SM760).
  - Every Hestia template's `# lazysite-template-rev:` moves to 2026-10-20 (t/lint/135),
    so the rollout sees the fcgi templates as changed.
- **The installer** creates `lib/Lazysite/WarmFork` (dist/config/classification.json,
  0755 as the rest of `../lib`). The first commit of this branch lacked the entry, so a
  fresh install refused to create the directory (t/tools/28, 31, t/integration/259
  failed on it); this commit adds it.

## Only where a front end uses it

Ruled 2026-10-20: the parent runs only where a front end hands it a call, decided
from what the site's front end is, with no setting unless no such fact exists. The
fact exists: every front end that hands the parent a call does it through the
site's pool (the one-rule pool's front door, and the split templates' endpoint
location), and a pool is `/etc/lazysite/pools/<instance>.conf` naming the docroot -
the conf `lazysite@.service` reads and `lazysite check` reports as `pool: yes`. A
plain-CGI site has none. `Lazysite::Paths::pool_conf_for` finds it, matched on
`DOCROOT=` as `lazysite check`'s `find_pool_conf` matches it (`LAZYSITE_POOLS_DIR`
moves the directory there and here, for a test), and the service's `wanted` asks
it first. So a plain-CGI site with the Odoo extension and lazysited has no parent;
a pooled one does; removing the pool conf stops the parent at the supervisor's next
gate reading. No setting was added.

A pool conf whose site still uses a pre-SM1226 split template (with no endpoint
location) gets a parent that is never called, until its vhost is regenerated from
the shipped template.

# What holds it

```datatable
columns: Ref | Threat | Protection | Test
widths: 0.9cm | 4cm | X | 4cm
---
W1 | The parent holds a credential or a person's data, and every child inherits it | the parent requires code and runs none of it; it reads no configuration or key; it never reads a request | t/lint/272 (static); t/integration/325 reads the parent's memory (`/proc/<pid>/mem`) after it has served signed-in requests and finds none of: the site's session secret, the Odoo connection key, alice's cookie signature, the tokens handed out, a parameter a visitor sent. It does find the docroot it was started with, which shows the reading is real
W2 | One request's state reaches the next | a fresh child per request, which exits | t/unit/daemon/15: three requests are three processes, children of one parent, none sees what the last left in a package variable, and each is its process's first; t/integration/325: alice, an anonymous visitor, bob, alice each see only themselves (their own CSRF token; the members' binding for the two members only)
W3 | A forged identity enters the child | the child's environment is the parameters less the identity variables; the endpoint verifies the cookie itself | t/unit/daemon/15: the sentinel, sid, flag and six trust headers sent as parameters are not in the child's environment, and nothing else is either; t/integration/325: X-Remote-User and the sentinel as FastCGI parameters, without a cookie and with bob's, through the pool and straight to the parent's socket: no token without a cookie, bob's with his
W4 | Children repeat each other's random numbers | `srand` in the child | t/unit/daemon/15: the probe draws `rand()` while it compiles (in the parent); three children draw three different numbers; t/integration/325: two calls record two call ids
W5 | A code change goes unnoticed in a long-lived parent | the parent watches what it loaded and exits 75; the service restarts it | t/unit/daemon/15: a changed endpoint file brings a new parent; the service keeps running and says why
W6 | An orphaned or stopped parent keeps a socket | the parent exits when re-parented, and removes its own socket | t/unit/daemon/15: kill -9 of the service, then TERM
W7 | A refused connection fails a page | the front door runs the CGI when nothing reached the parent | t/integration/325: parent stopped, the CGI answers (the cgi-bin shim records the run)
```

## t/lint/272: what the parent holds, by source

t/lint/269 classifies what a pooled worker keeps between requests. This lint asks
the question for the warm-fork parent, which runs no request at all. Using
t/lint/269's scan, now in t/lib/FileScope.pm, it holds three things.

1. **The set.** It computes what the parent loads with the parent's own function
   (`Lazysite::WarmFork::_names`). It checks that against a real preload in a fresh
   perl: every Lazysite file in that `%INC` is in the set.
2. **The variables.** Every file-scope variable of the set falls into one of three
   classes:
   - **Empty** at load. Only code the parent never runs could fill it.
   - **Constant.** Its initialiser is literals only. This is stricter than 269: a
     call, a variable or a `::` name is not literal, so `Time::HiRes::time()` is
     not.
   - **Computed at load**, and listed with what it holds. There are 31, all
     constants derived from constants, code references or compiled patterns,
     plus Timing's load clock and the child's time limit.
3. **What the parent runs:**
   - Outside the child, Lazysite::WarmFork calls no `Lazysite::` function but its
     own and the log line.
   - `preload` calls no function and opens no file; it reads only the sources it
     walks.
   - The endpoint runs nothing at load but its lib search and
     `exit main() if !caller`.
   - No module of the set runs a statement at load but `Manager::Common`'s
     `reset_request_context()`, which sets its request variables to "no request".

The vendored OOM modules the parent preloads are another project's code. 325
covers them by value.

# D5: the measurement

[[SM1164]] D5 (SM1144's bench): `tools/bench-surfaces.sh --surface odoo-oomd`
measures an Odoo endpoint call end to end. The call is a public read binding
(`core.read` of `res.partner`), answered by the real oomd from the vendored OOM
against OOM's fake Odoo (CliFake). It uses no network and never a real Odoo.

The bench is pinned to one CPU at nice 19 (and ionice 3), makes 20 sequential
calls, and makes nothing in parallel. It ran on the shared host on 2026-10-20 at a
load average of 0.7 to 2.1, in two rounds, before and after alternated. The figures
are medians in ms with p90 in brackets.

The split adds up each request's parts:

- **start** is `load` plus what no phase accounts for: the interpreter, the exit,
  and, in the warm-fork case, the fork and the hand-off;
- **endpoint** is config, identity, render and write;
- **call** is oomd's answer as the endpoint saw it.

```datatable
columns: Path | Before | After | Start | Endpoint | Call
widths: 4.4cm | 2.6cm | 2.6cm | 2.2cm | 2.2cm | 2cm
---
CGI (a process per call) | 112.0 (135), 110.9 (120), 115.2, 115.0 | the same path: 116.0, 128.4 | 64-73 | 27-32 | 20-23
One-rule pool, front door | 116.0 (125), 119.4 (124), 116.5, 125.3 | 17.0 (17.6), 17.9 (19.5) | 67 before; 4.9-5.3 after | 28 before; 4.3-4.4 after | 21-23 before; 7.5-7.9 after
Straight to the parent's socket | - | 15.6 (17.5), 16.6 (19.0) | 3.7-4.0 | 4.2-4.3 | 7.8-8.6
```

So an Odoo read through the pool goes from about 116 ms to about 17 ms on this host,
at this load. The lab measured about 200 ms of start-up on its host; on this host the
figure is about 100 ms.

The `call` phase also fell, from about 21 to 8 ms, because the OOM client's modules
are preloaded rather than compiled inside the call. What remains is oomd's own
answer and the endpoint's work. The `?csrf=1` call that pages make first
(`odoo-direct`) went from about 70 to 5 ms through the pool.

The before figures were first taken at 14:45 (load 2.1, the first two rows of the
pool line); the alternated rounds were at 15:07-15:08.

# Tests

- **t/unit/daemon/15-the-warm-fork-parent-forks-a-fresh-child-per-request.t.** The
  real program, started by the real service, with a probe in the endpoint's shape. It
  covers W2 to W6, the gate, the socket's modes, a 300 KB body over many records, a
  3 MB body the endpoint never reads, an endpoint that dies (a 500, and the next child
  is fresh), and the refused role.
- **t/integration/325-the-odoo-endpoint-runs-warm-forked-and-shares-nothing.t.** The
  arrangement is a production one:
  - one pool worker with the front door on;
  - the real endpoint's parent, started by its service;
  - the real oomd against CliFake;
  - a cgi-bin shim that records every CGI run.

  It covers W1, W2, W3, W4 and W7, and the Server-Timing `call;desc="oomd"`.
- **t/integration/326-a-split-templates-odoo-call-reaches-the-parent-through-the-pool.t.**
  325's arrangement with the front door off, as a split template's pool runs, and
  requests in nginx's shape and Apache's. Each shipped split template routes the
  endpoint to the pool's socket; a request reaches the parent with no CGI run, in
  both shapes, a binding call included; forged X-Remote-User, groups, sentinel,
  sid and flag as parameters are nobody, bob's cookie is bob, alice's is alice and
  the next anonymous visitor is nobody; a page through the same worker still
  renders; with the parent stopped the worker runs the CGI and it answers, in both
  shapes.
- **t/unit/daemon/16-the-odoo-endpoint-parent-runs-only-behind-a-pool.t.** Through
  the real supervisor with the daemon and Odoo extensions on: with no pool conf for
  the docroot (or one for another docroot) no odoo-endpoint service starts and
  Status lists none; a pool conf naming the docroot starts one whose parent
  answers; removing it stops the parent.
- **t/lint/272-the-warm-fork-parent-holds-code-only.t**, as above.
- **t/lint/269** now takes its scan from t/lib/FileScope.pm, unchanged, and reads
  `Lazysite::WarmFork::Wire` as part of the pool's resident set.

**Before and after.** On the base tree all three new files fail, because the modules
do not exist. With this branch, they pass with the neighbours listed in the
report: t/unit/daemon/*, t/integration/15, 49, 50, 110, 239, 288, 291-297,
t/unit/odoo/61, 63, 64, t/tools/170, 183, and lints 13, 14, 31, 38, 42, 43, 59, 131,
267-269 and the brief's.

**Sabotage**, each restored from a copy under tmp/:

| Change | What failed |
|---|---|
| no `srand` in the child | 15: "each child draws its own random numbers" |
| the child keeps the identity variables | 15: the environment subtest. 325 still passes: the endpoint reads none of them, so this is defence in depth, held by 15 |
| `preload` reads the Odoo key and the session secret into a package variable | 325: "does not hold the Odoo connection key" and "the site's session secret"; 272: "reads no file itself" |
| the parent peeks at each connection before forking (`recv` with `MSG_PEEK`) | 325: "a parameter a visitor sent", "alice's cookie signature" |
| the front door stops handing the endpoint to the parent | 325: every "no CGI ran" |
| the split-template worker no longer hands the endpoint on (the `_odoo_endpoint_request` branch removed) | 326 |
| a module computes a value from `%ENV` at file scope | 272 names the file, the line and the variable |
| the service's gate no longer asks for a pool | 16: a plain-CGI site's supervisor starts the parent |

On the previous commit's code (the slice before S2 and the gate), 326 fails on the
templates, both request shapes, the identity subtest and the fallback (5 of 8;
the page control passes), and 16 fails at its first subtest.

# Left open

- **S3: the rest of SM1082 C3's warm-fork surfaces**, the manager API and the
  wrapper's own actions, with the same runner.
- Sign-in, sign-out, the two-factor step and the identity refresh still run in the
  child in-process, as they did in the CGI (SM1164: oomd has no verb for them).

# Rulings (2026-10-20, "SM1226 warm-fork (n711)")

1. **The split templates: option (a)**, built above (S2).
2. **The parent runs only where a front end uses it**, built above: the fact is the
   site's pool conf, and no setting was added.

# Related

[[SM1082]] (R3, C3), [[SM1164]] (D5), [[SM1144]] (the bench), [[SM1169]] (lint 269),
[[SM1181]] (identity; S2/S4's forged-parameter cases), [[SM760]] (the run user),
[[SM411]] (the endpoint verifies its caller), [[SM1162]] (the body caps).
