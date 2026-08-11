---
title: "Plugin Manager and Plugin Config"
brand: plain
---

# Plugin Manager

Two adjacent menu items with a deliberate split: **Plugin Manager** decides what
runs, **Plugin Config** decides how it behaves. They are separate because
enabling something and configuring it are separate authorities.

## Enable and disable a plugin

Where
: Content -> Plugin Manager

Do
: Disable the form handler, submit a form on the public site, then re-enable it.

Expect
: Each plugin lists its name, description, version and state, read from the
  plugin's own `--describe`. With the handler disabled the form is refused with
  an honest error - not a false "thank you", which is the failure this behaviour
  exists to avoid.

Negative
: A plugin that fails to describe itself is listed as unavailable with its error,
  rather than silently omitted.

# Plugin Config

## Edit a plugin's settings

Where
: Content -> Plugin Config

Do
: Open the form handler, add an SMTP handler, save. Then open a child config -
  an individual form's `.conf`.

Expect
: The form is built from the plugin's declared schema, so the fields and their
  types come from the plugin rather than from the manager. Saving writes only the
  keys the schema declares. Child configs are listed per the plugin's declared
  pattern, with the excluded ones (`smtp.conf`, `handlers.conf`) kept out.

Negative
: Credentials and destinations live in operator-only config: an agent may
  *reference* a handler by id and can never read or set where it delivers.

## Notification routing

Where
: Content -> Plugin Config, and `lazysite/notify.conf`

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
