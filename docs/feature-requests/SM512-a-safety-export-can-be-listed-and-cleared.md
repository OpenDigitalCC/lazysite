---
title: "SM512: a safety export can be listed and cleared"
subtitle: "Every drop and every rebuild writes a safety export - correctly, and permanently: nothing listed them, nothing removed one, and the tree is denied to every write channel. Five accumulated on edge in a day."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE SITE AGENT 2026-08-24 across the day's retests - five exports under lazysite/db/rebuilds/ on edge, each from a throwaway table, each awaiting an operator's filesystem trip; the agent named it the same pattern SM508 closed for briefs (authorised to drop, not to tidy). SHIPPED 0.10.31 on the operator's pick: data-safety-exports / list_data_safety_exports (read: file, table, kind dropped|rebuild, stamp, size, mtime) and data-safety-export-delete / delete_data_safety_export (mutating, AUDITED with the file as target, explicit-file guard, the name validated to the EXACT shape the engine mints so no path separator can reach the unlink). Both manage_data, twins recorded. t/unit/data/25 pins listing, clearing, honest not-found and the name refusals. The tool description says the quiet part: an export is the only copy of the rows a drop removed - read it, or know it is a throwaway, before clearing."
---

# The gap

`drop_data_table` and a lossy `rebuild_data_table` each write a safety
export first - the right thing, and the reason a mistaken drop is
recoverable. But nothing listed them and nothing removed one, and
`lazysite/db/` is denied to every write channel, so every export was
permanent until an operator went to the filesystem. Five accumulated on
edge in one day of field testing.

# The fix

The SM508 pattern, for tables: a list (a read, skip-listed from the
audit) and a delete (mutating, audited with the file as its target,
explicit-file guard). The delete accepts only the exact name shape the
engine mints - `<table>-dropped-<stamp>.json` or `<table>-<stamp>.json`
- so no path separator can reach the unlink; refusals are by name,
before any filesystem look.
