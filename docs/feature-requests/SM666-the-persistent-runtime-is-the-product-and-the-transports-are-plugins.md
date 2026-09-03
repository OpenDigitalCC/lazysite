---
title: "SM666: the persistent runtime is the thing to build, and WebSocket, XMPP and the scheduler are what plug into it"
subtitle: "Release manager, 2026-08-28: 'possibly the persistent daemon separates from the websockets and xmpp, and is standalone, and they become plugins' - and it should carry a scheduler, so it can call timed functions"
brand: plain
standard-margins: true
status: candidate
---

# The decision this takes

SM221 asked, as its sixth open decision, whether the real-time daemon should
carry more than the browser socket - because SM646 (inter-instance messaging
over XMPP) needs something permanently connected in order to RECEIVE, and had
already concluded it should be a second consumer rather than propose a runtime
of its own. SM221 said that question had to be answered in phase 1, since a
process designed to hold browser sockets and a process designed to hold a
browser socket alongside a long-lived XMPP session are not the same process.

The answer is that neither is the process to design. **The persistent runtime is
its own thing, and everything that wants to live inside it is a plugin.**

# What the daemon becomes

A supervised, per-site process whose own job is small and boring: start, hold
state, supervise plugins, expose their status through SM222's service
lifecycle, and stop cleanly. It owns no protocol.

Three plugins fall out of it immediately:

WebSocket transport
: SM221's browser socket. Carries live updates out and commands in, and remains
  bound by SM221's load-bearing rule - the daemon is a transport, never a second
  write plane, and an inbound command executes through the existing control-API
  path with its gate, its `%MUTATING` rule, its scope confinement and its audit
  entry.

XMPP client
: SM646's long-lived session. Holds the roster and the anonymising map, and
  keeps SM646's own central rule - a report filed by a remote instance is
  content, never an instruction.

Scheduler
: NEW, and the reason this filing exists as much as the split does. A timer
  service that calls functions on a schedule, inside the stack.

# Why the scheduler belongs here and not in cron

The project's standing position is that a self-contained service carries its own
schedule; a stack that needs a line in the host's crontab to work is not
self-contained, and an operator who deploys it correctly still gets a broken
install. SM286's self-sufficiency argument for nginx is the same argument about
a different file.

Every scheduled thing the engine currently wants - retention sweeps, backup
rotation, token expiry, stats rollups, the export cache - either runs
opportunistically on a request that happens to arrive, or does not run. Running
maintenance on the back of a visitor's page view is why SM340 found a
3.5-second stats export: the work attaches itself to whoever is unlucky.

A scheduler in the runtime fixes the class, not the instance. It also has to
obey the same rule as the other two plugins: a scheduled job acts through the
same door as any other request, with an identity and an audit entry. A timer
that can call anything is a second write plane wearing a clock.

# What this changes about SM221

SM221's analysis stands - the transport choice, the phasing, the authentication
model, the `realtime` capability, the per-site recommendation, and the three
options for executing commands. What changes is what is built FIRST: the
supervisor and its plugin contract, with WebSocket as the first plugin proving
the contract rather than as the whole programme.

That ordering costs a little up front and settles SM221's open decision 6 by
construction: the daemon's shape cannot foreclose SM646, because SM646 is
another plugin against a contract that already has one working implementation.

# Decided 2026-09-03, and what it changes

The release manager took four decisions and set the programme's shape: the
daemon is one request, and everything whose scope overlaps it is reduced to a
module that depends on it. Those reductions are recorded in the register below
and noted in each filing.

**One runtime per instance.** This answers open question 4. Not per domain - a
lazysite instance serves many domains (SM151) and they are contexts within one
runtime, not separate processes. This also settles the tension the question
named: instance-wide work such as the backup store (SM577) now has a natural
home, because the runtime is instance-wide too. SM221's per-site recommendation
is superseded on this point; its reasoning was about a browser-socket process,
and the supervisor is not that.

**The scheduler is the first plugin, not WebSocket.** This changes the ordering
in "What this changes about SM221" above, and it is the more useful order.

A scheduler needs **no socket at all**. So it proves the supervisor, the plugin
contract, the lifecycle reporting and - critically - the job identity and audit
path, with **zero network surface** to get wrong at the same time. WebSocket
then proves the socket path against a contract that already has a working
implementation, which is the same argument this filing already makes for why the
runtime should not be designed around any one transport.

**Phase 1 does not egress.** A scheduled job calls in-process operations only.
Nothing fetches a URL, and the timer is internal. This is deliberate: a
scheduler that can call out is an SSRF engine pointed at whatever a site can
name, and the controls for that are SM579's subject rather than something to
inherit by accident.

**Dependencies are packages, not vendored code.** `libio-async-perl` may be a
dependency of the daemon if an event loop is wanted; the OOM library ships as
`libodoo-oom-perl` and is a dependency of the plugin that consumes it. Neither
is copied into this tree. Both are operator installs - this repository cannot
add OS packages.

# How the daemon is reached, and why it never listens on a port

The question "how does it listen, and can that be proxied" has one answer here,
and two standing constraints decide it before any preference does.

**SM286 self-sufficiency**: an operator must never have to hand-edit their web
server config. Lazysite generates its own, so a proxy mapping can live in *that*
template - which is self-sufficiency working, not an exception to it.

**Everything security-shaped already lives in the web server**: TLS, HTTP/2,
rate limits, the CSP and security headers (SM384 and the header rig). A daemon
binding its own port would need its own copy of all of it, and would be the only
part of the stack whose TLS nobody had reviewed.

So: **the runtime binds a Unix domain socket and never a TCP port.** Lazysite's
own server template maps the paths that need it. Nothing new is exposed to the
network, and a misconfigured daemon fails closed by being unreachable rather
than open by being reachable.

The two transports that might have argued otherwise do not. A WebSocket upgrade
proxies through both nginx and Apache. An ActivityPub inbox is an ordinary HTTP
POST. If a future plugin genuinely cannot be proxied, binding a port becomes a
decision with a filing of its own, not a default.

**Outbound is the exposure that matters, and it is the opposite direction.**
Inbound is bounded by the proxy; outbound is bounded by nothing until somebody
builds the bound. That is SM579's work, and it is why phase 1 has none.

# The security shape

Three rules, and the first two are inherited rather than new.

**The daemon is never a second write plane.** SM221's load-bearing rule holds
for every plugin: an inbound command executes through the existing control-API
path, with its gate, its `%MUTATING` rule, its scope confinement and its audit
entry. A transport carries a request; it does not decide one.

**A scheduled job has an identity and it is not `system`.** Open question 2
remains open and is now the gating decision for phase 1 rather than a general
concern - a job that acts as `system` is unconstrained by the capability model,
which is what the model exists to prevent. A timer that can call anything is a
second write plane wearing a clock. **Nothing should be scheduled until this is
settled**, because retrofitting a grant onto jobs that already run unconstrained
is the hard direction.

**Per-site context is a boundary, not a convention.** One runtime serving many
domains must refuse work it cannot attribute to a site. If a job or a request
cannot be resolved to a domain, it fails closed rather than defaulting to the
primary.

# The module register

The daemon is the request. These are its modules, each staying its own filing
and each now depending on this one:

| Module | Filing | What it needs from the runtime |
| --- | --- | --- |
| Scheduler | this filing, phase 1 | nothing but the supervisor - no socket, no egress |
| Connectors and egress | [[SM579]] | outbound policy, credentials, retry, and the return leg its own note says needs a listener |
| WebSocket transport | [[SM221]] | the local socket and the proxy mapping |
| XMPP client | [[SM646]] | a long-lived outbound session |
| Social syndication | [[SM090]] | an inbox that can be POSTed to, and a delivery queue with retries - both of which are the scheduler plus SM579 |
| Inbound email | [[SM184]] | a listener, and the sender-trust design that filing already names as its gating decision |

[[SM222]] is **not** a module. It is the lifecycle contract the supervisor
reports through, and the daemon is its first real consumer - which is worth
saying because SM222's key finding, that a disabled service still spawns and
then refuses, is exactly the class of thing a supervised runtime should stop
being true.

# What phase 1 actually is

Deliberately small enough to be boring, and shippable on its own:

1. A supervised process that starts, stops, reports status through SM222's
   verbs, and logs. No protocol, no socket, no egress.
2. A plugin contract with one implementation.
3. A scheduler: declarative jobs, a tick, a run record, and an audit row per
   run carrying a real identity.

Everything else in the register waits for a contract that has been proved by
something running.

# Open, and worth deciding before anything is built

1. **Does a plugin run in the supervisor's process or its own?** In-process is
   cheaper and lets a crash take everything down; a child per plugin isolates
   an XMPP library's bad day from the browser sockets. The FastCGI pool pattern
   (SM142/SM139) is the local precedent for the second.
2. GATING FOR PHASE 1, still open. **What is the scheduler's job identity?** Every job needs an actor for the
   audit trail, and `system:<name>` (SM659) is the obvious spelling - but a job
   that acts as `system` is unconstrained by the capability model, which is
   exactly what the model exists to prevent. A job identity with a real grant is
   the safer shape and a larger piece of work.
3. **Is the plugin contract the SAME contract as `plugins/*.pl`?** The engine
   already has a plugin word, and reusing it for something with a completely
   different lifecycle would be the sixth place a reader has to learn a
   distinction that is not written down (SM662's shape).
4. ANSWERED 2026-09-03 - one runtime per INSTANCE, see above. **One runtime per site, or one per host with per-site plugins?** SM221
   recommends per-site. A scheduler may argue the other way, since instance-wide
   work (the backup store is instance-wide, per SM577) has no natural site to
   belong to.

# Related

[[SM221]] (the real-time daemon this reshapes, and whose open decision 6 this
answers), [[SM646]] (inter-instance messaging, now a plugin rather than a second
consumer), [[SM222]] (service lifecycle and status, which the supervisor reports
through), SM142/SM139 (the per-site pool pattern), SM286 (self-sufficiency),
SM340 (what opportunistic maintenance cost), SM577 (the backup store is
instance-wide), [[SM659]] (`system:<name>` as a CLI actor spelling).

# Not started

Nothing is built. SM221 and SM646 are both still `candidate`.
