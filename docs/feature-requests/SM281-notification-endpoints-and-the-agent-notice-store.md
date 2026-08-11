---
title: "SM281 - The notification endpoints SM231 did not build, and the agent notice store it asked to leave room for"
subtitle: "SM231 shipped types, templates, routing and emission control over one endpoint. The SMTP endpoint, per-user addressing and the readable notice store are what remains."
brand: plain
status: candidate
status-note: "SPLIT from SM231 on 2026-08-11, which is now closed as shipped for the channel itself. NOT STARTED. Carries the two open decisions SM231 recorded and never resolved, plus the agent-messaging door it deliberately declined to build. The SMTP endpoint is S; the notice-store read surface is M and is also an SM239 parity item in its own right."
---

# SM281 - the rest of the notification channel

## What SM231 delivered, so this does not redo it

Types (a registry of seven, introspectable), templates (per type, per endpoint,
overridable per site, and the thing that finally delivers `url`), routing (which
types reach which endpoints, with the bell unroutable because it is the record),
and emission control (per type site-wide, and per form for the 690-versus-5
case). One endpoint: XMPP. Coverage of `Lazysite::Notify` went 56.7% to 89.6%.

## What remains

### 1. The SMTP endpoint (S)

SM231 named it: reuse the transport `plugins/form-smtp.pl` already has, as an
**operator notification** endpoint distinct from form delivery. The routing layer
already accepts an `smtp` token; nothing consumes it.

The care needed is the separation. Form delivery forwards a submission because
that is the form's purpose; notification tells an operator something happened.
They share transport and share no meaning, and merging them would give the
templates two masters - SM231 says so explicitly and it is still right.

### 2. Per-user addressing (M)

SM231's first open decision, unresolved: routing makes addressing expressible for
the first time, and `Notify.pm` has flagged per-user delivery as future work
since SM136. A `to` field on a notice - an account or a group - with unaddressed
notices staying broadcast as they are today.

It may genuinely be cheaper now than as a retrofit, which is what the filing
suspected. It was left out because routing-by-type was the part with a caller
waiting.

### 3. The notice store as a READ surface (M)

The half that makes the agent door real, and an [[SM239]] parity item on its own:
**`notifications` unlocks a manager page and has no remote surface at all.** The
bell reads the store for the manager; MCP and the control API cannot read it.

SM231 recorded the observation that motivates this, and it is worth repeating
because it was observed rather than speculated: **remote agents have been editing
the briefing document to talk to each other**, because it was the only durable,
shared, writable place they both had. A notice store is the right shape - polled,
not pushed, needing no daemon and no inbound transport.

To keep that door open, SM231 asked for four things. Two are now true (a notice
carries a type; types are the design's spine). Two are not:

- **a notice can be addressed** - item 2 above;
- **the store is readable, not only writable** - this item.

Plus one SM231 named and nobody has answered: **retention**. A message store that
grows forever is a different problem from a notice log that rolls, and the
difference should be decided before anything writes to it at volume.

## The second open decision, now answered

SM231 asked whether templates live in the theme namespace or the config
namespace. **Config**, decided when they were built: they are operator content,
not visitor-facing content, and a template in the theme namespace would travel in
a site package - so an agency handing a client a site would hand over its own
alerting text. Recorded here because the filing asked and the answer belongs with
the question.

## What to resist, unchanged from SM231

Threading, replies, read receipts, presence, delivery guarantees, digests,
timers, inbound actions and workflow. If agent messaging proves itself as flat,
polled, audited notices, the case for more can be made then on evidence.

## Related

[[SM231]] (the channel, closed), [[SM239]] (surface parity - the missing remote
read is one of its items), [[SM221]] (the real-time transport, correctly not
built), [[SM216]] (form-event outcomes are candidate types).
