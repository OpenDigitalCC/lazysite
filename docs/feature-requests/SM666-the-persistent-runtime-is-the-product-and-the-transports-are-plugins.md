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


# Addressing is an envelope concern, not an infrastructure one

Confirmed 2026-09-03, explicitly: **each lazysite instance has exactly one
daemon**, and that daemon serves all of the instance's domains. Not one per
domain, and not more than one per instance.

The follow-on decision matters more than it looks. Message routing needs to be
able to target a particular domain or subdomain - and that is carried **in the
envelope**, not by running a process per domain.

Stated as a rule, because the opposite is the mistake it would be easy to drift
into: a request to address one site is never a reason to start a second runtime.
Wanting per-domain delivery is an addressing feature; wanting per-domain
isolation would be an infrastructure decision, and this filing has taken the
opposite one deliberately.

Three consequences follow, and they are the design work this creates:

**Every message carries its target.** A WebSocket frame, a scheduled job, an
XMPP stanza and an ActivityPub delivery all need a target domain in the envelope
- not inferred from a connection, a config default or whichever site happened to
be loaded. Inference is what makes cross-site leakage a one-line mistake.

**An absent or unresolvable target fails closed**, per the boundary rule above.
It does not fall back to the primary domain, which is the tempting default and
the wrong one: the primary is precisely the site with the most to lose.

**A subscriber may only be addressed within its own site.** The envelope says
where a message is going; it does not by itself grant the right to send there.
Routing and authorisation stay separate, or the envelope becomes a capability.

# The service register

The daemon is the request. These are its services, each staying its own filing
and each now depending on this one:

| Service | Filing | What it needs from the runtime |
| --- | --- | --- |
| Scheduler | this filing, phase 1 | nothing but the supervisor - no socket, no egress |
| Connectors and egress | [[SM579]] | outbound policy, credentials, retry, and the return leg its own note says needs a listener |
| WebSocket transport | [[SM221]] | the local socket and the proxy mapping |
| XMPP client | [[SM646]] | a long-lived outbound session |
| Social syndication | [[SM090]] | an inbox that can be POSTed to, and a delivery queue with retries - both of which are the scheduler plus SM579 |
| Inbound email | [[SM184]] | a listener, and the sender-trust design that filing already names as its gating decision |

[[SM222]] is **not** a service of the runtime. It is the lifecycle contract the supervisor
reports through, and the daemon is its first real consumer - which is worth
saying because SM222's key finding, that a disabled service still spawns and
then refuses, is exactly the class of thing a supervised runtime should stop
being true.



# It conforms to ADR 0009, and that settles most of the shape

Instructed 2026-09-03: the runtime adheres to **[[0009-plugin-contract]]**. It is
not a special case, and it does not get its own idea of what "disabled" means.

That decides more than it looks, because ADR 0009 already specifies most of what
a plugin must declare. The runtime's `--describe` carries the same `owns` block:

    owns => {
        config_keys  => [...],                 # the runtime's own settings
        storage      => ['lazysite/daemon/'],  # schedules, run records, state
        endpoints    => [],                    # NONE in phase 1 - no socket
        capabilities => [...],                 # one per hosted component
        deps         => ['IO::Async', ...],    # SBOM gate cross-checks these
    }

Four consequences follow without further design:

**`storage` makes its state back up by declaration.** Schedules and run records
participate in content backups and site packages because they are declared, not
because somebody remembered an exclude list.

**`deps` cannot be undeclared.** `libio-async-perl`, if it is used, is declared
here and cross-checked against `sbom-deps.json` by the gate. A daemon quietly
adding a module fails the build.

**`endpoints` is empty in phase 1**, which is the declaration form of "no socket
yet" - and when phase 2 adds one it is declared rather than discovered.

**Capabilities registered by the runtime walk the same nine parity points** as
core ones. The contract does not exempt a plugin from the lints; it makes the
lints find it.

## Disabled means off, and for a daemon that is stronger than the ADR's own case

ADR 0009 states the rule as: *a disabled plugin executes nothing and says so,
with the house refusal shape.* For a CGI plugin, "off" is enforced at dispatch -
a request arrives and is refused.

**A daemon has no dispatch to refuse at.** Nothing arrives; the process either
exists or it does not. So conforming here means the stronger thing: **disabled
means the process never starts** - no supervision, no socket, no connections,
nothing scheduled, no state touched.

This is the same rule, not a different one. It is what "off means off" reduces
to when there is no request to say no to, and it is why the daemon cannot
inherit the current behaviour SM222 documents, where a disabled service still
spawns, reads its config and only then refuses.

**SM409 is not a dependency - it is already the mechanism.** CORRECTED
2026-09-03: an earlier version of this section said the runtime must not ship
until SM409 made `enabled` real. SM409 **shipped on 2026-08-19**, to the
semantic the release manager set at the time: contract-declaring plugins under
ADR 0009 are gated and **born disabled**, while legacy plugins stay untouched
until each one's own migration.

The runtime is a new ADR 0009 plugin, so it inherits both halves for free. It is
born disabled because that is what a conforming plugin now is, and its `enabled`
state is really consulted rather than displayed.

**What remains is ours, and it is small but load-bearing: supervision must
honour the flag.** SM409 gates *execution* - a disabled plugin's actions are
refused. For a CGI that is the whole of it, because execution only happens when
a request arrives. A daemon executes by existing, so the supervisor must read
the enabled state and **decline to start the process at all**, rather than
starting it and refusing work.

That is the piece SM222 describes from the other side: today a disabled service
still spawns, reads its config and only then refuses. Harmless for a CGI,
incoherent for a daemon - an unintended long-lived process holding credentials
is a different order of problem from an unintended CGI refusal.

# It ships as a plugin, and it comes disabled

Decided 2026-09-03. The runtime is delivered as a lazysite **plugin**, and it is
**disabled on install**. An operator turns it on deliberately; an existing
instance that upgrades gets nothing new running.

That is the right default for a long-lived process that holds credentials and
state, and it makes the whole programme opt-in rather than something every site
inherits because it shipped.

## "Disabled" has to mean off, and today it does not

This is where the decision bites, and it is worth stating rather than
discovering.

[[SM222]]'s key finding is that **a disabled service is not actually off**: the
web server still routes to it, the CGI still spawns, reads its config and only
then refuses - and the refusal contract is inconsistent between services. For a
CGI that is wasteful. **For a supervised daemon it would be incoherent**: a
disabled daemon that starts, connects, holds a socket and then declines to work
is not disabled, it is running with its output suppressed.

So the daemon cannot adopt the current meaning of disabled. Disabled must mean
**no process, no socket, no connections, nothing scheduled** - and the status
verb must be able to say "off because an operator turned it off" distinctly from
"off because it crashed", which is exactly the desired-versus-runtime split
SM222 already proposes.

The daemon is therefore not merely SM222's first consumer. **It is the case that
forces SM222 to be honest**, and the two should be scheduled together rather
than the daemon inheriting a lifecycle contract that does not yet mean what it
says.

## Two things were both called plugin - RESOLVED, see "Terminology, settled" below

The runtime is a **lazysite plugin** in the existing `plugins/*.pl` sense. It
hosts **daemon plugins** - scheduler, WebSocket, XMPP - in a new sense, with a
different lifecycle, a different contract and a different failure model.

This makes open question 3 more pressing rather than less. One word now covers
an outer thing and the inner things it contains, and a reader meeting
"disable the plugin" has to know which layer is meant before they can predict
what stops. Disabling the outer one stops everything; disabling an inner one
stops one transport.

SM662's shape is the warning: one concept described in several places drifts,
and the cost lands on whoever reads it later. **The naming should be settled
before the contract has users**, because it is free now and a rename across two
lifecycles later is not.

Neither name is chosen here. What is recorded is that the collision exists, is
structural rather than cosmetic, and belongs with question 3.


# Terminology, settled: the daemon hosts services

Decided 2026-09-03, closing open question 3.

**Lazysite has plugins. The daemon has services.** The runtime is itself a
plugin under ADR 0009; the things it supervises - the scheduler, and later the
WebSocket transport and the XMPP client - are **services**.

This deliberately reuses the existing word rather than inventing a fourth.
[[SM222]] already writes one lifecycle contract for "services and plugins":
start, stop, status, with a desired-versus-runtime split. A scheduler and a
WebDAV surface genuinely have that same lifecycle - they differ only in whether
they are request-spawned or supervised. A new noun would have created a
distinction that is not load-bearing, which is SM662's failure shape: one
concept described in several places, drifting, with the cost landing on whoever
reads it later.

So there is one lifecycle vocabulary across the whole system, and "disable that
service" means the same thing wherever it is said.

Three words were considered and rejected because they are already taken:
`worker` is the FastCGI/persistent CGI worker (SM381, 32 uses in the tree),
`handler` belongs to forms, and `module` collides with Perl's own. `unit` was
rejected because systemd supervises the daemon itself.

**The nesting is now legible rather than ambiguous.** Disabling the plugin stops
the runtime and every service in it; disabling a service stops that one. A
reader meeting either sentence can predict what stops, which was the whole
problem with two nested things sharing the word "plugin".

# A job is engine code, not configuration

**Rule, not a phase-1 convenience.** The set of schedulable jobs is defined in
engine code and reviewed as code. A site, an app, a theme or a plugin's
configuration **cannot declare a new job.**

Recorded as a rule because the alternative erodes quietly. The moment [[SM579]]
or an app wants a scheduled job, there is pressure to make the schedule a
configuration surface, and the day that happens "write a schedule" becomes
"execute code on a timer" - reachable by anyone who can write configuration.
Nobody notices the day a rule that was never written down stops holding.

What IS configuration is **which identity a job runs as**, and how often. What a
job DOES is code.

If an open surface is ever genuinely wanted, it arrives as its own filing with
its own security argument - not as a relaxation of this one.

# A job runs as a user, and never as `system`

Decided 2026-09-03, closing open question 2. This is stronger than the
`system:<name>` spelling the question offered, and deliberately so.

**Every job runs as a user identity.** Preferably a **purpose user** created for
the work - a service account - though an ordinary user account may be configured
if an operator wants that. What a job may never be is `system`, because
`system:*` is how the CLI acts and the CLI is unconstrained: a job running that
way would bypass the capability model entirely, which is what the model exists
to prevent.

**Two gates apply, not one.**

First, the identity must hold the capability that permits **running jobs at
all**. Proposed spelling `run_jobs`, following the house pattern; the name is
not yet fixed. An identity without it cannot be configured as a job's user, so
a job cannot be smuggled onto an account that was never meant to carry one.

Second, the job's actions face **the ordinary capability gate**, unchanged. A
job that writes rows needs what any other actor needs to write rows. There is no
scheduled-work exemption and no widening: the gate does not know or care that
the caller arrived on a timer.

**A purpose user is preferred for reasons that are operational, not
theoretical.** A human's account changes - passwords rotate, capabilities are
adjusted, people leave. A job quietly inheriting a person's rights either breaks
when they go or, worse, keeps working with the rights of someone who has left.
A service account is owned by the deployment rather than by a person, and its
grant can be read as a statement of exactly what the scheduled work is allowed
to touch.

**Failure is closed, in every direction.** If a job's configured user is
missing, lacks `run_jobs`, or lacks a capability the job's action requires, the
job **does not run**. It does not fall back to `system`, to the primary site's
owner, or to the identity that configured it. It logs a refusal naming what was
missing, in the house refusal shape, and the run record says it was refused
rather than that it succeeded quietly.

**The audit row names the real user.** Not `scheduler`, not `system` - the
identity the work was actually done as, so a row written at 03:00 is
indistinguishable in kind from one written by a person at noon, and answerable
by the same question: who was this, and what were they allowed to do.


# Each service gets its own process

Decided 2026-09-03, closing open question 1 - the last one. **The supervisor
runs a child process per service.** Not one process hosting all of them.

The reason is the one the question named: an XMPP library having a bad day must
not take down the browser sockets, and a service that leaks or wedges must be
restartable without stopping the rest. `SM142`/`SM139`'s per-site FastCGI pool
is the local precedent, and it is the same argument.

It also makes [[SM222]]'s desired-versus-runtime split fall out rather than need
building: **desired** is what the configuration says, **runtime** is whether the
child is alive. The supervisor knows both without asking anybody, which is
precisely the distinction SM222 exists to make reportable.

## What this obliges

**A restart policy, decided rather than improvised.** Backoff, and a crash loop
that is recognised as a crash loop. A service failing every two seconds must
report as **failed**, not as running - reporting a flapping child as healthy
would rebuild, in the daemon, the exact dishonesty SM222 was filed about.

**IPC becomes a real surface.** With services in separate processes, the
envelope described above crosses a process boundary to reach them. Routing a
message to a service is now inter-process rather than a function call, and that
boundary needs the same discipline as any other: a message carries its target,
an unresolvable target fails closed, and no service may address another site's
context.

**Phase 1 pays for this up front, and should.** One service still means
supervisor plus one child, which is slightly more work than hosting the
scheduler in-process. It is worth it: the contract is proved with real process
isolation by its first implementation, rather than being retrofitted when a
second service arrives and discovers the contract assumed a shared address
space.

## Two kinds of user, and they are not the same thing

Worth stating plainly, because conflating them would be easy and expensive.

**The OS user** is what the daemon and its children run as on the host - a
single system account owned by the deployment. It is a filesystem and process
concern.

**The job's user** is a lazysite identity in the capability model, holding
`run_jobs` and whatever the job's actions require. It is an authorisation
concern.

A job running as the lazysite user `jobs-nightly` does **not** imply a Unix
account of that name, and the capability gate is not a filesystem permission.
The daemon's OS identity says what the process may touch on disk; the job's
lazysite identity says what the work may do in the application. Neither
substitutes for the other, and a change to one is not a change to the other.

**`run_jobs` is confirmed** as the capability's name.

# What phase 1 actually is

Deliberately small enough to be boring, and shippable on its own:

1. A supervised process that starts, stops, reports status through SM222's
   verbs, and logs. No protocol, no socket, no egress.
2. A service contract with one implementation, running as its own child.
3. A scheduler: declarative jobs, a tick, a run record, and an audit row per
   run carrying a real identity.
4. Shipped DISABLED per ADR 0009, where disabled means the process never
   starts. SM409 already makes an ADR 0009 plugin born disabled with a real
   enabled state; what phase 1 adds is SUPERVISION honouring it, so the
   process is never started rather than started and made to refuse.

Everything else in the register waits for a contract that has been proved by
something running.

# The four questions, all answered 2026-09-03

1. ANSWERED 2026-09-03 - OWN PROCESS per service, see above. **Does a SERVICE run in the supervisor's process or its own?** In-process is
   cheaper and lets a crash take everything down; a child per plugin isolates
   an XMPP library's bad day from the browser sockets. The FastCGI pool pattern
   (SM142/SM139) is the local precedent for the second.
2. ANSWERED 2026-09-03 - a job runs as a USER, never as system, and that user must hold the job-running capability. See above. **What is the scheduler's job identity?** Every job needs an actor for the
   audit trail, and `system:<name>` (SM659) is the obvious spelling - but a job
   that acts as `system` is unconstrained by the capability model, which is
   exactly what the model exists to prevent. A job identity with a real grant is
   the safer shape and a larger piece of work.
3. ANSWERED 2026-09-03 - lazysite has PLUGINS, the daemon has SERVICES, reusing SM222's single lifecycle vocabulary rather than inventing a fourth word. See above. Originally: **Is the plugin contract the SAME contract as `plugins/*.pl`?** The engine
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
