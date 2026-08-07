---
title: "SM231 - A notification channel: types, templates, endpoints, policy and routing"
subtitle: "notify() is immediate-or-nothing to a single endpoint with a pre-built message. Make notification a channel the whole platform can speak through, so the things lazysite already knows can reach someone in a form they can act on."
brand: plain
status: candidate
status-note: "Raised 2026-08-07. Supersedes the ad-hoc 'milestone notification' idea, which needed cohort concepts lazysite has no business owning - the real defect is that notification has no delivery policy. Absorbs that as a channel property. SM229 (document the current behaviour) still ships first and is updated when this lands."
---

# SM231 - a notification channel

## Why

`Lazysite::Notify::notify` writes a record to the bell store and immediately
attempts one XMPP send. That is the whole delivery model. There is no policy, no
second endpoint, no template, and the caller must arrive holding a finished
string.

Two consequences.

**High-volume callers cannot use it.** A partner running a three-day programme
established the scale: 46 form steps per participant across 15 participants is
690 notification events, each of which would fire an immediate message. What
they need is five moments. The naive fix - teach forms about participants and
stages - would require lazysite to learn concepts it has no business owning. The
actual defect is narrower and general: **immediate-or-nothing is the only policy
available**, and every busy contact form, multi-step form, or site with several
forms at once meets the same wall.

**Everything the platform knows, it knows silently.** The record shape is
already generic - `notify()` takes a `type`, defaulting to `event`, plus a
`target` and a `url` - but there is exactly one caller and one type
(`submission`). Meanwhile lazysite routinely learns things nobody is told:

- a credential is about to lapse (SM220 - the confusion that prompted this line
  of work in the first place)
- a service is degraded, or its configuration disagrees with observed reality
  (SM222)
- a backup completed, or failed
- an audit finding appeared
- a quota is close to its ceiling

A publishing platform that knows these things and has no way to say them is the
gap. Forms are simply where it surfaced.

## What is true today

- `notify($docroot, { type, message, target, url })` appends to
  `lazysite/logs/notices.jsonl` and attempts XMPP. The bell store is the record;
  XMPP is strictly best-effort and time-boxed so a slow chat server can never
  make a CGI request hang.
- XMPP is one client per site, one recipient - an individual address or a MUC
  room. The module's own comment notes per-user addressing as a future feature.
- `message` is a finished string. `url` is stored in the record and **never
  delivered**, so the operator is told something happened and not where to go.
- `Template` is already a processor dependency, so TT bodies introduce nothing
  new.
- Form *delivery* (`dispatch_smtp` to `form-smtp.pl`, and the webhook handler) is
  a different mechanism entirely: it forwards the submission onward because that
  is the form's purpose. It shares transport with notification and shares no
  meaning.

## What to build

Five concepts, none large.

### Types

A registry of notification types, each declaring the variables it provides.
`submission` exists. Seed the ones the platform already knows - credential
lapsing, service degraded, backup outcome, audit finding, quota - so the channel
has more than one speaker on day one, and so the types that motivate it are not
left as future work.

### Templates

A TT body per type per endpoint, overridable per site. XMPP wants one line;
email wants a subject and a fuller body. Same event, same variables, different
rendering. This is the piece that makes `url` reach the operator instead of
sitting unused in the record.

### Endpoints

- **bell** - always written, always the record. Unchanged.
- **xmpp** - as today, rendered through a template.
- **smtp** - reusing the transport `form-smtp.pl` already has, as an operator
  notification endpoint distinct from form delivery.
- **webhook** - later, and only if asked for.

### Policy

Per type, and this is where the volume problem is solved:

- `immediate` - today's behaviour, the default
- `digest <window>` - coalesce into one message per window
- `threshold <n>` - send once n have accumulated

### Routing

Which types reach which endpoints, so a site can send service alerts to an
operator and submission notices to a room without one drowning the other.

## The plugin's half

Nothing above knows what a cohort is, and nothing should. A caller that wants
its events grouped supplies a grouping key, and the form handler already carries
typed per-handler configuration (`handlers.conf`, with declared field schemas per
handler type) - a `group_by` field and a policy selection are configuration
there, not engine features. Programme structure stays the partner's data.

## The hard part, named

Digest requires holding pending events and flushing them later, and lazysite is
CGI: there is no timer and, outside the FastCGI pools, no resident process.
Three options, and this is the request's central decision:

**Opportunistic flush.** The next request of any kind checks whether a digest
window has closed and sends. No new machinery, and no guarantee - a site with no
traffic at 3am sends nothing until someone arrives. Adequate for a busy site,
silently wrong for a quiet one.

**A timer.** A systemd timer or cron entry flushes on schedule. Reliable, and it
adds an installed component and a failure mode of its own.

**Flush on the triggering event.** Only useful for `threshold`, where the nth
event can send the batch itself. No new machinery, exact, and it cannot express
"tell me at the end of the day".

Recommend threshold-plus-opportunistic first, since together they cover the
motivating cases without new installed components, and add a timer only if a
quiet-site digest turns out to matter.

## Actionable notification

A partner asked to *"receive this notification on a phone and accept it
immediately rather than constantly opening email"*. Most of that is delivery,
which XMPP already does. The missing half is that the message carries no link -
`url` is recorded and discarded. Rendering it through the template closes most
of the gap for the cost of a template variable.

An explicit acknowledge or approve action is a larger question and should not be
smuggled in here: it implies inbound handling, which is a different surface with
its own authentication story. Deliver the link first and see whether the rest is
still wanted.

## Relationships

- **SM229** documents the notification behaviour that exists today. It should
  still ship on its own timetable - documenting what is true now has value even
  though this request will change it - and be revised when this lands.
- **SM220** and **SM222** each identified something worth telling an operator
  and had nowhere to send it. Both become types here.
- **SM216** established the form-events log; the outcomes it records are
  candidate notification types if anyone wants them.

## Open decisions

1. **Which digest mechanism**, per the three options above.
2. **Does per-user addressing come with this?** Routing makes it expressible for
   the first time, and the module already flags it as future work. It may be
   cheaper to do now than to retrofit.
3. **Do templates live in the theme namespace or the config namespace?** They
   are operator content rather than visitor-facing content, which argues for
   config, but they are TT, which argues for the existing template machinery.
4. **Does a failed endpoint retry?** Today delivery is best-effort with the bell
   store as the record, which is a defensible position and should be an explicit
   one rather than an inherited one.

## Not in scope

- Replacing form delivery handlers. They forward submissions because that is the
  form's purpose; they are not operator notification and merging them would give
  the templates two masters.
- A general job queue. Digest needs a pending list and a flush, not a scheduler.
- Any change to the bell store as the authoritative record.
