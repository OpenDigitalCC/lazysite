# SM142 - Persistent runtime: FastCGI pools ahead of packaging

Status: BUILT 2026-07-10 (engine increments 1-3 and 5; packaging = SM139).
Measured: cache-hit 62.2 ms CGI -> 0.4 ms FCGI (147x) on the reference host.
Driver: under plain CGI every request pays fork + exec + full Perl compile
(~50-100 ms) before any work happens; the render-cache-hit bench op is
62 ms of which the overwhelming majority is process start. Per-request
work keeps growing (SM140 access-log write, bad-URL check, notification
reads), all of it amortisable. The architecture docs have planned this
since D016; SM139 packaging is the moment to decide it, because a daemon
changes what the debs ship (service units, sockets, vhost config).

## Why now (sequencing with SM139)

A deb that packages the CGI pattern bakes in per-request process start
across the fleet, and retrofitting a daemon afterwards means re-packaging
the vhost templates, adding service management to already-deployed sites,
and a second migration. Deciding the runtime FIRST means SM139 ships the
right shape once: engine payload + per-site FastCGI pool units + proxy
config, with plain CGI as the zero-dependency fallback it has always been.

## The decision: dual-mode FastCGI accept-loop, one pool per site

Chosen shape (option b below). The processor (and later the other hot
CGIs) gains a FastCGI mode: when spawned under a FastCGI process manager
it services requests from an accept loop - modules compiled once,
`reset_request_state()` + `local %ENV` per iteration; when invoked as
plain CGI it behaves exactly as today. One pool per site (the PHP-FPM
model Hestia already understands): DOCROOT is fixed at spawn, so the
file-scoped docroot-derived state stays valid for the life of the worker,
and site isolation is process-level, exactly as strong as today.

- Web-server side: Apache `mod_proxy_fcgi` (already present on the Hestia
  hosts for PHP) or nginx `fastcgi_pass` to a per-site unix socket.
- Process side: `FCGI` + `FCGI::ProcManager` (Debian: libfcgi-perl,
  libfcgi-procmanager-perl) - prefork workers, socket ownership per site
  user, worker count and max-requests-per-worker (memory hygiene)
  configurable; systemd template unit `lazysite@<domain>.service` shipped
  by the SM139 environment debs.
- Plain CGI remains the DEFAULT and the dev-server path - FastCGI is the
  packaged production pattern, not a new requirement. A site under
  FallbackResource-to-CGI keeps working untouched.

## Options considered

a) Plain CGI forever
: zero risk, but every added per-request feature pays the compile tax
  again across the fleet, and SM139 would package the slow pattern.

b) FastCGI accept loop in the existing scripts (CHOSEN)
: smallest distance from the current code - the D016 groundwork
  (`reset_request_state()`, `local %ENV` in main(), the per-request reset
  discipline documented in the processor) was built for exactly this.
  ~4-8 ms cache-hit floor per the performance doc's estimate.

c) PSGI/Plack (Starman/CGI::Compile shim)
: a real framework migration or an emulation shim; more moving parts, new
  dependency surface, and the shim path gives little over (b) while the
  full rewrite is disproportionate for four CGIs.

d) Own prefork HTTP daemon
: reinventing the process manager AND the web-server integration; the
  web server stays in front regardless (TLS, static assets), so the extra
  ambition buys nothing over FastCGI behind it.

## What the work actually is

1. **State-hygiene audit** (the hard part, mostly done historically):
   every file-scoped mutable variable in the processor either (a) derives
   from DOCROOT - safe, fixed per pool; (b) is per-request - must be in
   the reset path. Known per-request state already handled: %ENV
   (localised), peek cache + site-vars memo (reset_request_state), 
   %PREVIEW_CONTEXT, %AUTH_CONTEXT. Known NEW residue to fix: the SM140
   %ACCESS_REC reset currently lives in the file-scope main wrapper -
   it must move inside the per-iteration path.
2. **The accept loop**: `while ($req = FCGI::Request(...)->Accept) { ... }`
   wrapping the existing wrapper block (reset -> main() -> access record),
   conditional on being spawned FCGI (FCGI.pm detects; plain CGI falls
   through to the single-shot path). Lazy-require FCGI so the CGI path
   adds no dependency.
3. **Same treatment for lazysite-auth.pl** (second-hottest: every manager
   request) and later manager-api/dav if measurement justifies.
4. **Pool manager + unit**: FCGI::ProcManager prefork (workers=2-4,
   max-requests ~500), unix socket in the site's runtime dir, systemd
   template unit - shipped and wired by SM139's environment debs; the
   Hestia deb writes the per-domain vhost `SetHandler proxy:unix:...`.
5. **Bench evidence**: new bench ops for the FCGI path (expected ~10x on
   cache hits); the existing CGI ops keep guarding the fallback path.
6. **Fleet caveat**: memory per site pool (~2 workers x ~30-40 MB) x 17
   sites is the trade for the latency win; worker counts are per-site
   tunable and a pool can be disabled per site (falls back to CGI).

## Dependencies / asks

- Debian packages on the deploy host: libfcgi-perl,
  libfcgi-procmanager-perl (ask the owner; never CPAN).
- SM139 increments reordered: SM142 lands first (engine capability), then
  SM139 packages CGI-fallback + FCGI-pool patterns together.

## Open questions

- Socket dir convention on Hestia (per-domain runtime dir vs /run/lazysite/).
- Whether the dav CGI (WebDAV bursts from agents) earns a pool in phase 1.
- Max-requests / memory ceiling defaults - measure on the fleet first.
