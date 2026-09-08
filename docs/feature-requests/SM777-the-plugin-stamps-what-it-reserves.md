---
id: SM777
title: "SM777: the plugin stamps what it reserves"
subtitle: "Reported from a site on 0.12.1: with timestamps: true, created_at and updated_at were refused from every writer ('maintained by the plugin') and never written - rows read created_at=None. SQLite.pm said the caller supplies them; no caller did. A site that turned the flag on for trustworthy provenance got neither a stamp nor its own field back, and fell back to client-supplied free text a writer can forge."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm777-the-plugin-stamps-what-it-reserves. Tables.pm stamps created_at and updated_at on insert, updated_at on update, and both on a CSV import (the file's values are dropped as before) - UTC to the second, the value layer's datetime spelling. The descriptor's reply (data-table, describe_data_table) carries a note when a table without the flag declares a text or datetime field named *_at: written by the caller, can be any value, set timestamps: true. /docs/data-tables says what the flag does. t/unit/data/61 proves insert, update, import, the reserved refusal still standing, and the note."
---

# What the field saw

A `qa` table with `timestamps: 0` and an `added_at` text field carried three
rows stamped fourteen hours in the future, exactly a minute apart, `:00`
seconds - a generated series, not a clock. Two rows shared a `saved_at` to the
millisecond. Row order in the site's view comes from those fields.

The site author's own fix - turn `timestamps` on - was tried on a fresh table:
the body was refused (`'created_at' is maintained by the plugin and cannot be
written`, correct) and after an insert and an update both columns read `None`.
`data-migrate-plan` had nothing outstanding; the flag read `1`.

# What was true

`Schema.pm` created the columns; `Value.pm` reserved them; `SQLite.pm`'s
`insert_sql` says "timestamps are supplied by the CALLER when the descriptor
declares them"; `Tables.pm` never supplied them. The name was reserved and the
value never produced - since the option shipped.

# What is built

- `Tables.pm::_stamp`: `created_at` and `updated_at` on insert, `updated_at`
  on update, both on an imported row (an export's own values are dropped as
  before). One clock, the value layer's spelling: `YYYY-MM-DDTHH:MM:SSZ`.
  Every write path goes through it - manager row-save, the control API, MCP,
  the endpoint, a connector's kept answer, the CSV import.
- The descriptor's reply carries `notes` when a table without the flag
  declares a `*_at` text or datetime field: "'added_at' is written by the
  caller and can be any value: nothing stamps it. For a time the plugin
  stamps and no writer can forge, set timestamps: true". The field's second
  question, answered where the author looks.
- `/docs/data-tables` says what the flag does and what a look-alike field is.
- `t/unit/data/61`: insert stamped, update moves `updated_at` and leaves
  `created_at`, import stamped with the plugin's clock, the reserved refusal
  still holds, the note names the fields.

# Not built

A `*_by` stamp (who wrote the row) - the engine records the actor in the row
audit (SM-series row audit) and nowhere in the row. If a site needs it on the
row, that is a separate ask.
