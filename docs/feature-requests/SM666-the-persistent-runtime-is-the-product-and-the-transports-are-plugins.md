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

# Open, and worth deciding before anything is built

1. **Does a plugin run in the supervisor's process or its own?** In-process is
   cheaper and lets a crash take everything down; a child per plugin isolates
   an XMPP library's bad day from the browser sockets. The FastCGI pool pattern
   (SM142/SM139) is the local precedent for the second.
2. **What is the scheduler's job identity?** Every job needs an actor for the
   audit trail, and `system:<name>` (SM659) is the obvious spelling - but a job
   that acts as `system` is unconstrained by the capability model, which is
   exactly what the model exists to prevent. A job identity with a real grant is
   the safer shape and a larger piece of work.
3. **Is the plugin contract the SAME contract as `plugins/*.pl`?** The engine
   already has a plugin word, and reusing it for something with a completely
   different lifecycle would be the sixth place a reader has to learn a
   distinction that is not written down (SM662's shape).
4. **One runtime per site, or one per host with per-site plugins?** SM221
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
