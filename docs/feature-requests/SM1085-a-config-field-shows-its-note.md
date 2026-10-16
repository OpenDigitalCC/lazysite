---
id: SM1085
title: "SM1085: an extension config field shows its note"
subtitle: "Each field's explanation from the extension's descriptor appears as an info mark beside its label on the Configure page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: manager
status-note: "SHIPPED on n598: starter/manager/plugin-config.md, plugins/odoo.pl; t/unit/manager/342."
---

# What happened

The release manager, on the Odoo extension's Configure form: "what does Extra
operation packs mean on odoo config - add some tooltips to the items".

The descriptor already explained the field. Any `config_schema` entry may
carry a `note`, and most of Odoo's did. But `renderForm` drew each field's
label and input and never its note, on every extension. The explanations
existed and nobody could read them.

# What shipped

- `renderForm` puts a field's note beside its label as the info mark the
  Extensions page already uses (ⓘ, `title` and `aria-label`, reachable by
  keyboard). A field without a note gets no mark. This applies to every
  extension.
- Odoo's "Timeout per call" gained a note. "Extra operation packs" now says
  what a pack is, when to leave the field blank and how to name a pack, with a
  generic example namespace.

t/unit/manager/342 drives `renderForm` in node and checks that every Odoo
config field carries a note.
