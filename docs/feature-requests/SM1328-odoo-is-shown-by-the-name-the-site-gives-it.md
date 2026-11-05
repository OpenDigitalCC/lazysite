---
id: SM1328
title: "SM1328: Odoo is shown by the name the site gives it"
subtitle: "Every dialog label and error text a visitor or a manager reads said \"Odoo\". One setting, odoo_display_name (default Odoo), is now said in all of them; an empty value names nothing, and each text reads whole without it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 52 (tmp/rulings-2026-10-22.md, \"4 November\"), Q7, on T-13 of the inbox triage (tmp/inbox-triage-2026-11-04.md)"
area: odoo
status-note: "SHIPPED (PENDING) on n744: Lazysite::Odoo::Name, the endpoint's errors, the browser helper, /odoo-signin, /login and the unknown-runs panel. t/unit/odoo/121, t/unit/processor/172."
---

# What was asked

Ruling 52 (2026-11-04): "One setting odoo_display_name (default \"Odoo\") in every dialog
and error text; empty means no name." T-13 found dialog labels and error texts saying
"Odoo" with no way for a site to change it (`lazysite-odoo.js`, `Odoo.pm`'s fault
sentences). Moved to 0.16.5 by ruling 63.

# What shipped

- **The setting.** `odoo_display_name` in `lazysite/odoo.conf`, on the Odoo extension's
  settings ("Name shown for Odoo", default `Odoo`, which the form shows filled in).
  Absent is `Odoo`, so every text reads as it did; a value is that name, without its
  outer spaces; an empty value is no name.
- **One reader**, `Lazysite::Odoo::Name`: `display_name($dir)`, and `phrase($named,
  $plain, $dir)`, which says `$named` with each `{name}` replaced, or `$plain` when the
  name is empty. Each text that names Odoo is written twice, so neither has a hole.
  `Lazysite::Odoo::said` and the session module's `_said` are its two callers on the
  server; the processor reads it through `_odoo_display_name` (loaded on first ask, so a
  page that names Odoo nowhere never loads it). When the extension moves
  (rulings 66-77) it moves as one module.
- **The page endpoint's errors**: every fault sentence (access, credential, session,
  validation, missing, other, transport, configuration, internal), the refusals that
  name Odoo (redirect, oversize, read-only, another connection, stale, unknown outcome,
  refused before it answered), the sign-in's own (password and code refused, no
  session, sign-in ended, two-factor, groups not read, no login said, the unsecured-site
  refusal), a refused change's withheld reason, the unknown-answer sentence, a session
  binding without a sign-in, and a key not set.
- **The browser helper** (`lazysite-odoo.js`): the sign-in dialog's label, message and
  field labels, "could not be reached", and the line an unknown write draws. It reads the
  name from the script tag the processor adds (`data-ls-odoo-display-name`); a page that
  loads the helper itself has no attribute and the helper says "Odoo".
- **The pages**: `/odoo-signin`'s text, the `::: odoo-signin` button (the component is
  given `odoo_display_name` as the page body is) and `/login`'s link to `/odoo-signin`.
  A name is text, escaped where it lands.
- **The manager's Unknown Odoo writes panel**: "no run is waiting", "a person signed in
  to …", the unknown-outcome status and the close confirmation, from the
  `display_name` the `odoo-unknown-runs` listing now answers.

Empty, the texts read, for example: "Sign in", "Sign in to continue.", "Login",
"Password", "No answer came. Try again.", "It is not known whether this change was
made.", "That sign-in was not accepted", "Sign in another way" (`/login`'s link).

# What keeps the name Odoo

The extension's own name ("the Odoo extension is switched off", the Extensions page's
Odoo row and its Unknown Odoo writes button, "the Odoo page"), the Odoo daemon, "the Odoo
endpoint", "Odoo binding" as a kind of handler, OOM's version refusals, the extension's
settings labels and notes and their validators (the Odoo group xml id), a binding's
configuration refusals, `lazysite check`, the MCP tool descriptions, logs and operator
docs. These name the component or its configuration, not the system a person uses.

# Tests

- **t/unit/odoo/121** (new): the reader for absent, a name, spaces and empty; every
  fault and refusal kind, the internal fault, the session's no-sign-in and transport
  texts and the unknown-answer sentence - all say Odoo by default, the name in exactly
  the places they said Odoo, and with an empty name none names anything, none has a
  hole and each still says something; the unknown-runs listing answers the name; the
  browser helper's seven texts for no attribute, a name and an empty name (under node,
  t/lib/odoo-name-harness.js).
- **t/unit/processor/172** (new): `/odoo-signin`'s text and button, `/login`'s link and
  the script tag's attribute, for absent, a name and empty; a name with markup in it is
  escaped in all three places.
- **t/unit/processor/171**: the script tag it matches now carries the attribute.
- **t/unit/processor/113**: its record re-recorded for the one new stash key,
  `odoo_display_name` (recorded as `CODE`); nothing else in it changed.

With the changed sources put back to the base (the new module kept), t/unit/odoo/121
fails at its second subtest and t/unit/processor/172 fails all four. With only
`lazysite-odoo.js` put back, 121's helper subtest fails; with only `Session.pm`, its
error subtest.

# Not done

- **A page already cached keeps the name it was rendered with** until it is next
  rendered; saving the extension's settings does not clear the page cache. The
  setting's note says so.
- The manager panel's texts are covered through the listing's answer, not by driving
  the panel's script.
- Binding configuration refusals ("a session binding runs as the person signed in to
  Odoo") are a sysop's configuration texts and keep "Odoo"; if they should take the
  name too, it is two lines in `Lazysite::Odoo::Binding`.
