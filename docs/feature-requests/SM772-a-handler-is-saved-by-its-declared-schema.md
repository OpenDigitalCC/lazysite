---
id: SM772
title: "SM772: a handler is saved by its declared schema"
subtitle: "0.13.6 on edge (136E-04 not run): the Form Handler plugin offers 'Connector (SM579)' with a required 'connector' field, the wizard draws no field for it, and handler-save drops the value with ok:true. A connector handler that names no connector; a db handler in the same position (table, fields dropped); an smtp handler losing attach_files. The public-trigger half of connectors could not be configured on any surface."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm772-a-handler-is-saved-by-its-declared-schema. handler-save reads the plugin's handler_types and keeps every key the chosen type's schema declares beside the base and SMTP transport keys; a required key without a default that is absent is refused by name ('connector is required for a connector handler'); a type the plugin does not offer is refused naming what it offers; a required key with a default is filled. The wizard renders any type without a hand-drawn form from its schema (renderSchemaFields) and reads it back on save. t/unit/lib/07 uses the real plugin and proves every schema key of every type round-trips (fails on the old writer 11 ways); t/lint/106 holds the schema fallback."
---

# What the field saw

136E-04 starts by binding a public form to the `connector` handler naming
`probe`. The handler could not be created:

- The wizard offers the type and draws Name and Enabled - no field for the
  connector. It renders from three hand-written functions
  (`renderSmtpFields`, `renderFileFields`, `renderWebhookFields`), not from
  the schema the plugin publishes.
- `handler-save` given the complete object returned `ok: 1` and stored the
  handler **without** `connector`. The `file` handler beside it kept its
  `path`.
- `handlers.conf` is writable nowhere else, correctly.

"A required field, dropped, with ok:true." The type looked available,
saving it looked successful, and what existed was a connector handler that
named no connector.

# What was true

`action_handler_save` copied a fixed list of keys. `connector` was not on
it; nor were `db`'s `table` and `fields`, nor smtp's `attach_files` - every
key added to a schema after the list was written. The plugin declares the
schemas and the wizard already fetches them (`handler_types[].schema`, with
labels, types, defaults and `required`); neither surface read them.

# What is built

- `_handler_types`: the writer asks the form-handler plugin for its
  declared types, the one way a plugin describes itself (ADR 0009).
- `action_handler_save` keeps every key the chosen type's schema declares,
  beside the base keys and the SMTP transport keys; fills a required key
  that has a default the way the wizard fills it; refuses a required key
  without a default that is absent - `connector is required for a
  connector handler`; refuses a type the plugin does not offer, naming
  what it offers. If the plugin cannot be described (absent from the
  registry), the built-in list is used and a WARN says so.
- The wizard: `renderSchemaFields` draws any type without a hand-drawn
  form from its schema (text, email, boolean; label, note, required), and
  `saveHandlerFromWizard` reads those fields back and refuses a missing
  required one by name before posting.
- `/docs/connectors` names both ways to add the handler and the refusal.
- `t/unit/lib/07` carries the real plugin in its fixture: a connector
  handler round-trips; one without a connector is refused by name and
  nothing is written; `db` keeps `table` and fills `fields`; smtp keeps
  `attach_files`; an unknown type is refused; and for every declared type,
  every schema key round-trips - the check the field asked for, which
  fails the moment a type gains a key the writer does not keep.
- `t/lint/106` holds that the step-2 form falls through to the schema
  renderer and that the save reads it back.

# The smaller thing the field folded in

`connector-delete` with `id` in the query string answers "connector id
must be a-z, 0-9, - or _" - a charset complaint for a missing parameter.
The connector actions now say `id is required (send it in the JSON body)`
when the id is absent (on SM768's branch, beside the other store answers).
The class - a declared body parameter that is missing, answered by name
across the control API - is SM773, a candidate.
