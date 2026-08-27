---
title: "SM514: a safety export can be read, judged from the listing, and offered back"
subtitle: "SM512 shipped list and delete. The briefs store had a read before it had a delete, and that third verb is the whole reason an orphan could be judged before it was cleared. An export could only be listed and destroyed."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE SITE AGENT 2026-08-25 (inbox filing) after clearing twelve exports on the operator's ruling and KEEPING one - paintings-20260823T175821Z.json, a lossy rebuild export of a REAL table, the only copy of rows that rebuild could not carry - because nothing could open it: no read action, and lazysite/db/ is 403 over DAV. Their rule: WHEN A STORE GAINS A DELETE, CHECK IT HAS A READ. SHIPPED 0.10.32 (the beta build, on the operator's instruction to include it): the listing carries each export's row count and a key sample; data-safety-export-read / read_data_safety_export returns table, key, fields and rows (a read, skip-listed); data-safety-export-restore / restore_data_safety_export offers the rows back through import_rows' own plan-then-apply and live-write coercion - columns the table still has restore, columns it no longer has are REPORTED as not_restored_columns rather than refused (a lossy export is lossy by definition; re-declare the columns and restore again), and a drop export's table must be re-declared first, which the refusal says. Mutating, audited with the file as target. t/unit/data/25 drives a real drop-export round trip and a lossy restore."
---

# The rule

*When a store gains a delete, check it has a read.* List plus delete lets
an agent tidy but never judge, and tidying without judging is how the one
file that mattered goes the same way as the six that did not.

# The three verbs

- **Judge from the listing** - row count and a key sample per export.
- **Read** - the export as data: table, key, fields, rows.
- **Offer back** - a plan without `apply`, a write with it, through the
  same path a CSV import takes. Columns the table no longer has are
  reported, not refused; a drop export needs its table re-declared first.
