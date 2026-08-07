---
title: "SM231 - A notification channel: types, templates, endpoints and routing"
subtitle: "notify() has one caller, one type, one endpoint and a pre-built message, and the url it records is never delivered. Make notification a channel the platform can speak through - and stop there, because what happens next is workflow and lives outside."
brand: plain
status: candidate
status-note: "Raised 2026-08-07, scope tightened by the operator the same day. Emission is opt-in per caller; there is deliberately NO digest, NO timer and NO inbound action - the consumer of a notification is frequently a component rather than a person, and lazysite's job ends at emitting a well-formed, addressable event. Supersedes an earlier 'milestone notification' idea that would have taught forms about cohorts."
---

# SM231 - a notification channel

## Why

`Lazysite::Notify::notify` writes a record to the bell store and immediately
attempts one XMPP send. One caller, one type, one endpoint, and the caller must
arrive holding a finished string.

**Everything the platform knows, it knows silently.** The record shape is already
generic - `notify()` takes a `type`, defaulting to `event`, plus a `target` and a
`url` - but there is exactly one caller and one type (`submission`). Meanwhile
lazysite routinely learns things nobody is told:

- a credential is about to lapse (SM220 - the confusion that started this line of
  work)
- a service is degraded, or its configuration disagrees with observed reality
  (SM222)
- a backup completed, or failed
- an audit finding appeared
- a quota is close to its ceiling

**The url is recorded and discarded.** An operator is told that something
happened and not where to go. That single omission accounts for most of what
makes the current notification hard to act on.

**Notification fires on every submission, unconditionally.** A partner running a
three-day programme established the scale: 46 form steps per participant across
15 participants is 690 events where five were wanted. The fix is not to
accumulate and batch. It is that **a caller should say when it wants to speak** -
five configured emissions rather than 690 suppressed ones.

## Who the consumer is

Frequently not a person. A notification's natural recipient is a component that
reacts: reads what arrived, processes it, publishes the result. That component
belongs to whoever owns the workflow, and it is where approval, sequencing,
retries and business rules live.

This bounds the request precisely. Lazysite emits a well-formed event carrying
enough identity to act on - what happened, to what, and where it is. It does not
learn what should happen next, does not wait for an answer, and does not hold
state between events.

## What is true today

- `notify($docroot, { type, message, target, url })` appends to
  `lazysite/logs/notices.jsonl` and attempts XMPP. The bell store is the record;
  XMPP is best-effort and time-boxed so a slow chat server can never make a CGI
  request hang.
- XMPP is one client per site, one recipient - an individual address or a MUC
  room. The module notes per-user addressing as future work.
- `message` arrives as a finished string; `url` is stored and never sent.
- `Template` is already a processor dependency, so TT bodies add nothing new.
- Form *delivery* (`dispatch_smtp` to `form-smtp.pl`, and the webhook handler)
  forwards a submission onward because that is the form's purpose. It shares
  transport with notification and shares no meaning.

## What to build

### Types

A registry of notification types, each declaring the variables it provides.
`submission` exists. Seed the ones the platform already knows - credential
lapsing, service degraded, backup outcome, audit finding, quota - so the channel
has more than one speaker on day one.

### Templates

A TT body per type per endpoint, overridable per site. XMPP wants one line; email
wants a subject and a fuller body. Same event, same variables, different
rendering. This is what finally delivers `url`.

### Endpoints

- **bell** - always written, always the record. Unchanged.
- **xmpp** - as today, rendered through a template.
- **smtp** - reusing the transport `form-smtp.pl` already has, as an operator
  notification endpoint distinct from form delivery.
- **webhook** - later, and only if asked for.

### Routing

Which types reach which endpoints, so service alerts can reach an operator while
submission notices reach a room, without one drowning the other.

### Emission control

A caller declares whether an event notifies, and optionally under what condition.
For forms that is configuration on the existing typed per-handler config
(`handlers.conf`), which already carries declared field schemas per handler type:
a form that should announce itself does, and the other forty-one steps stay
quiet. No state, no accumulation, no flush.

## Explicitly out of scope

**No digest and no batching.** Accumulating events to send later requires holding
pending state and flushing it, which requires a timer, which lazysite does not
have. Emission control solves the same problem without any of it.

**No timer.** See the design note below.

**No inbound action.** An approve or acknowledge action implies a second inbound
surface with its own authentication story, and it is workflow rather than
publishing. A notification carries a link; what the recipient does with it is
theirs.

**No workflow.** Sequencing, approval, retry and business rules belong to the
component that consumes events.

**No replacement of form delivery handlers.** They forward submissions because
that is the form's purpose; merging them into notification would give the
templates two masters.

## Design note, held and not requested

If lazysite ever needs to do something on a schedule, the expected shape is a
**systemd timer calling a single entry point, with installable triggers
registered against it** - a mini cron, consistent with how services are packaged
today. Recorded so it is not reinvented ad hoc.

There is no current use case. Scheduled work in a partner's solution belongs in
that partner's own component, which can then drive lazysite over MCP or the
control API at whatever cadence suits it - and can be changed when their needs
change without reshaping the platform. This note is a pattern, not a request, and
should not be built speculatively.

## Relationships

- **SM229** documents the notification behaviour that exists today. It ships on
  its own timetable - documenting what is true now has value even though this
  request will change it - and is revised when this lands.
- **SM220** and **SM222** each identified something worth telling an operator and
  had nowhere to send it. Both become types here.
- **SM216** established the form-events log; its outcomes are candidate types if
  anyone wants them.

## Open decisions

1. **Does per-user addressing come with this?** Routing makes it expressible for
   the first time, and the module already flags it as future work. It may be
   cheaper now than as a retrofit.
2. **Do templates live in the theme namespace or the config namespace?** They are
   operator content rather than visitor-facing content, which argues for config;
   they are TT, which argues for the existing template machinery.
3. **Does a failed endpoint retry?** Today delivery is best-effort with the bell
   store as the record. That is defensible and should become an explicit position
   rather than an inherited one.
