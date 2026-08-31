---
title: "SM646 - inter-site real time back-end comms: instances can send notifications out and cannot hear anything back, so nothing can be reported TO a lazysite"
subtitle: "Operator, 2026-08-27: 'inter systems communications. plugin to register xmpp account, locally anonymises messages before sending, holds a map, so no local user exposed, yet messages can be routed to sender'"
brand: plain
standard-margins: true
status: candidate
status-note: "PROPOSED 2026-08-27 by the operator. `notify-xmpp` (SM136) already gives every site one XMPP account and one recipient, and its own header names the gap: 'Per-user recipient addressing is a future feature'. This is the larger version of that gap - traffic today is one-way, one-recipient, and best-effort, so an instance can tell a person something and nothing can tell an INSTANCE anything. THE ASK: instances join a room or message each other directly, a remote instance files a report to a lazysite, a lazysite publishes updates, and every message is anonymised locally before it leaves - the instance holds a map so a reply can be routed back to the originating local user without that user's identity ever crossing the wire. THE MAP IS THE WHOLE DESIGN, and it is also the whole risk: it is a re-identification table, so where it lives and what may read it decides whether this feature is safe. THE HARD CONSTRAINT IS ARCHITECTURAL, not cryptographic: a CGI is never connected, so an instance can SEND from a request and cannot RECEIVE at all. DEPENDS ON SM221, which already designs the daemon this needs - a per-site real-time proxy copying the FastCGI pool's packaging and supervision, with its own `realtime` capability - and a process holding a WebSocket open is a process that can hold an XMPP session open. This should be a second consumer of that daemon rather than a fourth answer to the same question, so SM221 is the decision to take first. SM221's load-bearing rule, "the daemon is a transport, never a second write plane", is this filing's untrusted-input rule reached from the other direction. ALSO DEPENDS ON SM485 (the notification endpoints are decided and unbuilt) - this is a new endpoint plus a direction the channel has never had. SIZE: L."
---

# What exists, and what it cannot do

`notify-xmpp` delivers operator notifications - a new form submission, a request
awaiting a response - to one JID or one MUC room, from one account per site,
through `Lazysite::Notify` and the xmpp-lite connector. It is strictly
best-effort; the bell store remains the record.

| | Today | Proposed |
|---|---|---|
| Direction | out only | out and in |
| Recipients | one, configured | a room, or a peer, chosen per message |
| Who is named | the site | an anonymous handle per local user |
| Replies | none possible | routed back to the originating user |
| Peer | a person's chat client | another instance, or a person |

# The constraint that decides everything else, and it is already scoped

Receiving needs something to be *connected*. Every lazysite surface is CGI - a
request arrives, a script runs, it exits - which is exactly why the existing
plugin is send-only and best-effort: a request can open a connection, push a
line and close it. XMPP delivers to a connected session, and a CGI is never
connected.

**That does not make this the product's first long-lived process, and an
earlier draft of this filing was wrong to say so.** Per-site FastCGI pools
(SM142 runtime, SM139 packaging) are already resident: `debian/lazysite@.service`
is a systemd template unit, one pool per site, and `tools/lazysite-pool.pl`
starts as root, binds a socket, chowns it, drops privileges and execs the
processor under `Restart=always`. The project accepted a supervised per-site
daemon some time ago.

**SM221 already designs the daemon this needs.** It proposes a per-site
real-time proxy - `lazysite-realtime@`, copying the pool's packaging, privilege
handling and supervision almost exactly - to carry live updates out and
commands in over WebSocket, with its own `realtime` channel capability and
killswitch. Its motivation is polling: the bell, the SM103 change markers and
the audit viewer all ask on a timer, so each is simultaneously too slow and too
expensive.

A process that holds a WebSocket open is a process that can hold an XMPP
session open. **This filing should be a second consumer of SM221's daemon, not
a fourth answer to the same question**, and SM221 should be built or rejected
before this is designed further. If SM221 is not built, the fallback here is
polling a mailbox on a schedule the stack owns - no presence, latency in
minutes, and it needs somewhere messages wait, which MUC history or an
offline-message store already provides.

## SM221's load-bearing rule is this filing's rule too

> the daemon is a transport, never a second write plane

An inbound command there is validated and then executed through the existing
control-API path, so the capability gate, the mutating-verb rule, scope
confinement and the audit entry all apply unchanged and in one place. The
failure mode it designs against is the security model forking into two answers
to "may this account do this".

That is the same sentence as this filing's "an inbound message is never an
instruction", arrived at from the other direction - and it is a good sign that
two designs written months apart converge on it. A peer's report is content; if
it ever causes an instance to act, it must do so by the same door, with the
same gate, as any other request.

# The map, and why it is the sensitive part

Anonymisation here is not encryption - it is pseudonymisation with a local
lookup table. Its properties matter more than its algorithm:

- **It never leaves the instance.** Operator-only, like `notify-xmpp.conf`.
  Nothing serves it, no capability reads it, no export includes it. An instance
  that can read another instance's map has undone the feature entirely.
- **A handle is stable per (local user, peer), not global.** One handle per
  local user across every peer lets two peers compare notes and re-identify by
  correlation. Per-pair handles cost nothing and remove that.
- **A handle is not a capability.** Receiving a message addressed to a handle
  must confer nothing: routing a reply to a local user is a delivery decision,
  never an authorisation one.
- **Rotation must be possible** without losing the ability to route replies to
  conversations already in flight, or the first privacy incident has no remedy
  short of silence.

# An inbound message is untrusted input

This is the property most easily lost. A report filed by a remote instance is
data written by a system this instance does not control, and it will be
rendered to an operator and possibly read by an agent.

It is never an instruction. Not to the operator's agent, not to a plugin, not
to anything that runs. It is stored, attributed to the peer that sent it and
the handle it came from, and displayed as content - the same footing as a form
submission, which the product already treats correctly.

Anything that would let a peer's text change what an instance DOES belongs to a
different feature with a different threat model.

# Where it joins what is already decided

- **SM221** - the real-time proxy daemon. The dependency, and the reason this
  filing does not propose a runtime of its own. See above.
- **SM222** - the mini-init start/stop/status contract. Whatever holds the XMPP
  session is a service, and services in this product answer to that contract
  rather than to whatever each one invents.
- **SM485** - the notification endpoints are decided and unbuilt. This adds an
  endpoint and, more significantly, a direction the channel has never had. The
  routing and template machinery from SM231 is the right place for it, and the
  `default.xmpp` template already models per-endpoint rendering.
- **The capability.** Sending notifications sits under `notifications`. Talking
  to other instances is a bigger decision than the bell - it decides whether
  this site converses with systems the operator may not run - and by the same
  argument SM633 made for the service switches, it should be its own grant
  rather than arriving as a side effect of one that already means something
  smaller.
- **The registration step.** "Register an XMPP account" implies the instance
  provisioning its own identity rather than an operator pasting credentials
  into a form. That is a genuinely different setup flow from the existing
  plugin's, and worth designing as one - an instance that can register accounts
  can register many.

# What would make this worth building

An instance filing a report to another instance, arriving in the bell,
attributed to a handle, replied to, and the reply reaching the right local
person - with the peer never learning who that person is, and the operator able
to read the whole exchange. That is one scenario, and it exercises the map, the
routing, the storage and the untrusted-input rule at once. It is the thing to
build first and the thing to demonstrate.
