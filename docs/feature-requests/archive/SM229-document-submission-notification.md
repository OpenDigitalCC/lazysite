---
title: "SM229 - Document submission notification"
subtitle: "Every form submission raises a notification, delivered to the manager and optionally over XMPP. It is undocumented outside the source, and it is the feature that makes human-in-the-loop workflows viable."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit 7b537fd). Raised 2026-08-06. Documentation-only. SM136 shipped the capability; nothing outside the codebase describes it, and a partner designing an intake workflow in August 2026 specified polling because they did not know it existed. Implementation targeted for the next release."
---

# SM229 - document submission notification

## Why

When a form is submitted, `plugins/form-handler.pl` calls `_notify_submission`,
which raises a notification through `Lazysite::Notify::notify`. That notification
appears in the manager's bell store and, where the `notify-xmpp` plugin is
enabled and configured, is delivered over XMPP to a nominated address.

The mechanism is well built. Delivery is best-effort and time-boxed so a slow
chat server can never make a visitor wait on a form POST, and the stored
notification is the record if delivery fails. It is one client per site, sending
to a single recipient - an individual address or a room.

None of this appears in the AI briefings, in `/docs/forms`, or in
`/docs/ai-briefing-publishing`. It exists in `lib/Lazysite/Notify.pm`, in
`plugins/notify-xmpp.pl`, and nowhere a partner or operator would look.

The consequence is not a missing feature but a missed architecture. A partner
designing an intake workflow in August 2026 - questionnaire in, output back -
had no way to learn that the site could tell them a submission had arrived. The
alternatives available to someone in that position are polling, or a webhook to
somewhere else, or building a notification path that already exists.

This is the feature that makes the whole human-in-the-loop pattern viable:
material arrives, a person is told, a person acts. Undocumented, it may as well
not be there.

## What to write

### 1. A section in `/docs/forms`

What happens after a submission is stored: the notification is raised, where it
appears, what it contains, and what it deliberately omits. State plainly that
the message carries the form name and time and **not** the submitted content, so
it is safe to receive on a phone in a public place.

### 2. Configuration in `/docs/configuration` or a dedicated page

Enabling the `notify-xmpp` plugin, the `lazysite/notify-xmpp.conf` client
config, the single-recipient model, and the Debian package the connector needs.
Note that delivery is best-effort by design and that the bell store is
authoritative.

### 3. A paragraph in `/docs/ai-briefing-publishing`

A partner should learn, from the briefing it is told to read, that it does not
need to poll for submissions. One paragraph, cross-referencing `/docs/forms`.

### 4. Name it in the `manage_forms` and `read_submissions` unlocks

`Lazysite::Capabilities` describes what each capability unlocks. Notification is
part of what a form does; the capability description is a place a partner
actually reads.

## Verification

- `/docs/forms` describes the notification, its content, and its omissions.
- Enabling XMPP delivery is documented end to end, from plugin to conf to
  recipient.
- `/docs/ai-briefing-publishing` tells a partner that submissions announce
  themselves.

## Not in scope

- Any change to `Lazysite::Notify` or the plugin. The capability is correct as
  built.
- Additional delivery channels. If email or webhook notification is wanted, that
  is a separate request; the form handler already has webhook and SMTP delivery
  handlers, which are a different thing and should not be conflated with
  operator notification in the documentation.
