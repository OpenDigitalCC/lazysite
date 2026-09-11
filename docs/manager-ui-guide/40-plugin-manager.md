---
title: "Extension Manager and Extension Config"
brand: plain
---

# Extension Manager

Two adjacent menu items with a deliberate split: **Extension Manager** decides what
runs, **Extension Config** decides how it behaves. They are separate because
enabling something and configuring it are separate authorities.

## Enable and disable a extension

Where
: Content -> Extension Manager

Do
: Disable the form handler, submit a form on the public site, then re-enable it.

Expect
: Each extension lists its name, description, version and state, read from the
  extension's own `--describe`. With the handler disabled the form is refused with
  an honest error - not a false "thank you", which is the failure this behaviour
  exists to avoid.

Negative
: A extension that fails to describe itself is listed as unavailable with its error,
  rather than silently omitted.

# Extension Config

## Edit a extension's settings

Where
: Content -> Extension Config

Do
: Open the Form SMTP extension's Configure and set the mail transport; run its
  Validate action. Then open the Form Handler's Submissions.

Expect
: The form is built from the extension's declared schema, so the fields and their
  types come from the extension rather than from the manager. Saving writes only the
  keys the schema declares. The Form Handler's row links to the Handlers page, where
  handlers and form bindings are configured (see *Handlers*), and opens the
  submissions viewer.

Negative
: The password is never shown back: a blank password field keeps the stored one.

## Notification routing

Where
: Content -> Extension Config, and `lazysite/notify.conf`

Do
: Set `notify: off` in one form's `.conf` and submit it; submit a different form.
  Then set `emit.submission: off` site-wide and submit both.

Expect
: The silenced form rings nothing - no bell entry, no chat message - while the
  other still does. The site-wide key silences the whole type. Both default to
  on, so a site that sets neither behaves as it always did.

Negative
: Silencing is not suppression-after-the-fact: a silenced notice is never
  written, so it cannot accumulate in a store nobody reads.
