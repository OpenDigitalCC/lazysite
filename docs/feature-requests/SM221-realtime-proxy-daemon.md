---
title: "SM221 - Real-time proxy daemon (a side service bridging the control API to WebSocket)"
subtitle: "A separate per-site daemon that carries live updates out (and commands in) for the manager and, later, public pages - reusing the existing credential stores and capability model rather than inventing a second write plane"
brand: plain
status: candidate
status-note: "Design + analysis written 2026-07-27 at the operator's request. NOT built. Recommends WebSocket as the transport (WebRTC only for a genuinely peer-to-peer phase 4), a manager-first phasing, and a new `realtime` CHANNEL capability with its own killswitch. Several decisions are deliberately left open at the end - this is a design to argue with, not a plan to execute. Supersedes the streaming half of SM103 phase 2 (SSE) and would carry SM103's phase-3 presence ambition."
---

# SM221 - real-time proxy daemon

## Why

Every live signal in the manager is polled today. The notification bell, the
SM103 recent-change markers and the audit viewer all ask the control API on a
timer, which means each is simultaneously too slow (a change is invisible until
the next poll) and too expensive (every open manager page costs requests
forever, most returning nothing new). SM103's own status note parks phase 2
(a live audit stream) as "a larger real-time programme to scope separately".
This is that scoping.

The operator's framing: a **separate side daemon**, an API-to-WebSocket (or
WebRTC) proxy providing real-time updates **in and out**, usable by the
**manager and the public**, reusing the existing permission structure with
**an additional capability and group**. That framing is right, and the analysis
below mostly concerns how far it can go before it collides with something
lazysite has deliberately committed to.

## What already exists (the constraints that matter)

A persistent runtime is **not** unprecedented - this is the single most
important input to the design:

Per-site FastCGI pools (SM142 runtime, SM139 packaging)
: `debian/lazysite@.service` is a systemd **template** unit - one pool per site,
  `systemctl enable --now lazysite@example.com`. Identity lives in
  `/etc/lazysite/pools/%i.conf` (`DOCROOT=`, `USER=`, optional `GROUP=`,
  `WORKERS=`, `MAX_REQUESTS=`, `SOCKET=`) because systemd cannot template
  `User=` from an instance name. `tools/lazysite-pool.pl` starts as root, binds
  `/run/lazysite/%i.sock`, chowns it `USER:GROUP` 0660 so the web server can
  connect, **drops privileges**, puts the listen socket on fd 0 and execs the
  processor. `Restart=always`, sandboxed with `ProtectSystem=full`/`PrivateTmp`.

This is the pattern SM221 should copy almost exactly. It settles packaging,
per-site isolation, privilege handling and supervision, and it means the
project has already accepted a long-running per-site process.

The rest of the ground:

Authentication has two established paths
: A signed session cookie (`lazysite_auth`, HMAC-SHA256, HttpOnly/SameSite,
  `lazysite-auth.pl`) and `lzs_` machine tokens verified against
  `lazysite/auth/user-settings.json`, with SM212 lifetime + sliding renewal.

Authorisation is groups-only and already centralised
: `caps_for()` / `effective_groups()` (`lib/Lazysite/Auth/Settings.pm`) resolve
  capabilities as a union across a user's groups, including compound groups.
  Channels (`ui`, `webdav`, `api`, `mcp`) map to service killswitches through
  `channel_service()` (`lib/Lazysite/Capabilities.pm`). Content confinement is
  `dav_scope` / `group_scopes` at group level.

The control API already encodes every authorisation decision
: `lazysite-manager-api.pl` holds the `%need` capability gate, the `%MUTATING`
  set (mutations are cookie-manager-only; token clients are refused), the CSRF
  requirement for cookie callers, and the audit call for every action.

The event sources already exist and are append-only
: `lazysite/logs/notices.jsonl` (SM113/SM136 bell, `lib/Lazysite/Notify.pm`),
  `lazysite/logs/audit.log` (`lib/Lazysite/Audit.pm`, one line per material
  action), and the SM216-2 form-event log. Append-only files are exactly what a
  tailing daemon wants.

Two architectural commitments constrain the shape
: ADR 0001 - the render path loads **no** Lazysite modules (it keeps a
  deliberate local copy of capability resolution). Render-path separation - the
  processor is the only always-on unauthenticated entry point, and the write
  plane is separate. A real-time daemon must not blur either.

Dependencies are Debian-packaged and minimal
: `docs/reference/host-dependencies.md` lists the whole runtime surface
  (Template, Text::MultiMarkdown, LWP, FCGI, FCGI::ProcManager, IO::Socket::SSL,
  Archive::Zip, Net::XMPP). Anything new must be a Debian package, declared, and
  ideally **lazy-required so a site that never enables the daemon pays nothing**
  - the pattern FCGI already uses.

## Transport: WebSocket, not WebRTC (for what is actually being asked)

The request named "WebRTC or WebSockets". They are not close substitutes, and
the distinction decides most of the design.

WebSocket - recommended
: One TCP connection, HTTP `Upgrade`, bidirectional framing, proxied natively by
  both nginx and Apache, `wss://` inherits the site's existing TLS. Debian ships
  `libprotocol-websocket-perl` (framing only, no I/O loop - it composes with a
  plain `IO::Socket` accept loop, mirroring how `lazysite-pool.pl` already
  works). For a server that must fan events out to many authenticated clients
  and accept commands back, this is precisely the right tool and the cheapest
  thing that works.

WebRTC - not for phase 1-3
: A data channel requires signalling, ICE candidate exchange, STUN (and TURN for
  the ~10-20% of clients behind symmetric NAT), and DTLS-SRTP. There is no
  credible pure-Perl implementation; it would mean a non-Perl component
  (libdatachannel or equivalent) and a STUN/TURN dependency, which is a hosting
  burden and a new external-service relationship - awkward against the no-CDN,
  self-contained posture. WebRTC earns its complexity only for **peer-to-peer**
  traffic that should not transit the server: operator-to-operator presence,
  cursors, voice/video, direct file transfer. That is SM103's phase-3 ambition,
  and it is a legitimate **phase 4** - but building it first would pay the
  hardest bill for the least-wanted feature. Note also that a server-mediated
  data channel is strictly worse than a WebSocket: same server hop, far more
  machinery.

Server-Sent Events - the honest alternative
: One-way, dead simple, no new dependency (it is just a long-lived HTTP response
  with a `text/event-stream` content type), and proxy-friendly. If phases 1 and
  3 (server to client only) were the whole ambition, SSE would be the right
  answer and the daemon could be ~200 lines. It cannot carry commands inbound,
  so it loses phase 2. **Worth deciding explicitly** rather than defaulting to
  WebSocket: if inbound never materialises, SSE is less to own forever.

## Architecture

```
browser  ──wss://site/realtime──▶  nginx/apache  ──unix socket──▶  lazysite-realtime.pl
                                                                    (per-site daemon,
                                                                     systemd lazysite-realtime@)
                                          reads (tail)   ┌── lazysite/logs/notices.jsonl
                                                          ├── lazysite/logs/audit.log
                                                          └── lazysite/logs/*-events.jsonl
                                          commands ──────▶ the SAME control-API code path
                                                           (cap gate, %MUTATING, audit)
```

The load-bearing rule: **the daemon is a transport, never a second write
plane.** An inbound command is validated and then executed through the existing
control-API path, so the `%need` gate, the `%MUTATING` cookie-only rule, scope
confinement and the audit entry all apply unchanged and in one place. If the
daemon ever grows its own write logic, the security model forks and the project
acquires two answers to "may this account do this" - which is the failure mode
worth designing against from the first line.

Three implementation options for "execute through the control API":

1. **Exec the CGI per command** (recommended first cut) - the daemon runs
   `lazysite-manager-api.pl` as a child with the request in the environment,
   exactly as the web server would. Zero duplicated authorisation, trivially
   correct, and per-command cost is a process spawn - fine at manager
   command rates (a few per minute), not fine at page-view rates.
2. **Load the manager-api modules in-process** - faster, but the daemon then
   holds the write plane in memory and must replicate the CGI's request
   plumbing; higher risk of drift.
3. **Loopback HTTP to the site's own control API** - clean isolation, but adds
   an internal HTTP hop and an authentication problem (the daemon needs a
   credential to act as the user, which is precisely the ambient authority the
   token model avoids).

Option 1 is recommended: correctness first, and the cost profile matches the
workload. Option 2 is the optimisation if measurement ever justifies it.

## Authentication and the new capability

The daemon must **not** invent authentication. Two paths, mirroring today:

- **Cookie**: the client sends the existing `lazysite_auth` cookie on the
  WebSocket handshake (same origin, so it is sent automatically). The daemon
  verifies the HMAC with the same secret and the same code the auth wrapper
  uses. This is the manager case.
- **Token**: an `lzs_` token presented in the handshake - in a header or the
  subprotocol field, **never in the URL** (query strings land in access logs and
  `Referer`). This is the agent/integration case.

Then a new **channel capability**, alongside `ui`/`webdav`/`api`/`mcp`:

`realtime`
: May hold a real-time connection at all. Mapped through `channel_service()` to
  a new `realtime_enabled` killswitch, **default off**, like every other remote
  surface. An operator grants it to a group exactly as they grant `mcp` today -
  which is the "additional capability and group" the request called for, and it
  arrives free of new mechanism because the grid, the dormancy indicator
  (SM180), the capability map and the permission guards are all driven from the
  same tables.

Crucially, `realtime` is only the **channel**. What an account may *see* and
*do* over that channel remains the existing action capabilities: a subscription
to the audit topic requires `audit`; to the bell, `notifications`; to
submissions, `read_submissions`; a command requires whatever the control API
already requires. **The new capability adds a door, not a privilege** - which is
the property that keeps the model comprehensible.

Two authorisation subtleties that need a decision:

- **Re-authorisation over a long connection.** Capabilities are resolved
  per-request today, so a revoked grant takes effect on the next request. A
  connection held for hours would bypass that unless it re-resolves. Proposal:
  re-resolve on every inbound command, and on a timer (say 60s) for
  subscriptions, dropping topics that are no longer permitted. A revocation must
  never be defeated by an open socket.
- **Mutations.** `%MUTATING` is cookie-only, deliberately (SM127: an account
  that can drive the interactive manager must not also drive the site over a
  remote token). The same rule should hold on the socket - cookie-authenticated
  connections may send commands, token connections are read-only - unless
  someone consciously decides otherwise.

## The public channel (harder than it looks)

The request wants this available to the public as well as the manager. It can
be, but only under constraints the project has already committed to:

- **A persistent connection is itself an identifier.** For as long as it is
  open, it correlates a visitor's activity - which is what lazysite's "no
  trackers, no analytics cookies, daily-salted anonymised keys" commitment
  exists to prevent. The public channel must therefore carry **no per-visitor
  state, no per-connection identity, and must not feed analytics**. Connection
  metadata must not be logged beyond aggregate counts.
- **Public pages are cached** as `.html` siblings and served identically to
  every visitor. A real-time channel must not become a per-visitor rendering
  path; the natural design is that it carries *invalidation and small facts*
  ("this page changed", "the form accepted your submission"), and the page acts
  on them.
- **It must be progressive enhancement, always.** If the daemon is off or down,
  every public page must behave exactly as it does today. A public site whose
  content depends on a WebSocket would be a serious regression in both
  resilience and the no-JS-requirement posture that the SM216 spam work just
  reaffirmed.
- **Resource exposure is real.** An anonymous, unauthenticated persistent
  connection is a cheap DoS surface: file descriptors, memory, and per-site
  worker attention. Needs a connection cap, per-IP limits, an idle timeout, and
  a hard message-rate limit - and honestly, needs to be off by default with its
  own killswitch separate from the manager channel.

Given all that, public real-time is genuinely valuable for a narrow set of
things (live-updating a page an editor is changing; confirming a form
submission; a "new content" nudge) and should be **phase 3**, after the
authenticated case has proven the daemon in the field.

## Phasing

1. **Manager, one-way.** Server-to-client events for the bell, recent-change
   markers and the audit viewer. Replaces three polling loops. Authenticated by
   cookie, gated by `realtime` + the existing per-topic action capabilities.
   This is where nearly all the value is, and it is the cheapest phase.
2. **Manager, bidirectional.** Inbound commands proxied to the control API
   (option 1 above). Enables live editing signals and, later, collaborative
   affordances.
3. **Public, one-way, anonymous.** Page-changed / form-accepted facts under the
   constraints above, own killswitch, progressive enhancement, strict limits.
4. **WebRTC data channel** - only if operator-to-operator presence or
   peer-to-peer transfer is actually wanted, and only after 1-3 are bedded in.

Phases 1 and 2 subsume SM103 phase 2; phase 4 is SM103 phase 3.

## Failure, operability, and what must not regress

- **The site works without it.** The daemon is additive. Manager pages keep
  their polling fallback (or degrade to manual refresh); public pages ignore it
  entirely.
- **Supervision is systemd's job**, exactly as for the FastCGI pool -
  `lazysite-realtime@<site>.service`, `Restart=always`, privilege drop, unix
  socket, sandboxing. SM221 must not build a process supervisor; see [[SM222]],
  which should own the uniform status/report contract this daemon reports
  *through*.
- **Backpressure and limits**: max connections per site and per IP, max
  subscriptions per connection, outbound queue bound with slow-client
  disconnect, idle ping/timeout.
- **Observability**: connection count, dropped clients, events delivered - which
  is exactly the "richer status" [[SM222]] is being written to standardise.
- **Security review is mandatory before build**, not after: origin checking on
  the handshake, TLS-only (`wss://`) except loopback, no credentials in URLs,
  re-authorisation as above, and a fresh look at whether the daemon's ability to
  exec the control API creates any privilege path that the CGI does not already
  have.

## Acceptance (phase 1)

- With `realtime_enabled` off (default), no listener exists, nothing is
  advertised, and every manager page behaves exactly as today.
- A manager user in a group granted `realtime` receives a bell notification
  within a second of the event, with no polling.
- A user without `notifications` cannot subscribe to the bell topic even with
  `realtime`; a user without `realtime` cannot connect at all.
- Revoking a group grant drops the affected subscriptions within the
  re-resolution window without needing the client to reconnect.
- Killing the daemon leaves every manager page functional.

## Open decisions (for the operator)

1. **SSE or WebSocket?** If inbound commands (phase 2) are genuinely wanted,
   WebSocket. If not, SSE is materially less to own.
2. **Is phase 4 (WebRTC/presence) a real goal**, or an idea worth dropping? It
   drives whether the phase-1 protocol should be designed to carry it later.
3. **Public channel: in or out of scope for v1** of this feature?
4. **Do token clients get the socket at all**, or is it cookie-only to start?
5. **One daemon per site (mirrors the pool, simple, isolated) or one per host
   (fewer processes, needs multi-tenant care)?** Per-site is recommended.

Related: [[SM103]] (recent-change markers; phases 2-3 folded in here),
[[SM222]] (service lifecycle + status, which this daemon should report
through), SM142/SM139 (the FastCGI pool pattern this copies), SM212 (token
lifetime), SM180 (dormant-capability indicators, which `realtime` inherits), and
the privacy commitments in `docs/FEATURES.md`.
