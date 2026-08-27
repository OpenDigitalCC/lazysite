---
title: "SM489: a rebuild with nothing to do dropped and recreated the table anyway"
subtitle: "Nothing was lost, so nothing was confirmed - correct in isolation, and wrong when nothing needed doing. Found by a field agent being careless in a useful way"
brand: plain
standard-margins: true
status: shipped
status-note: "FROM THE FIELD AGENT'S 0.10.27 VERIFICATION, met while sweeping data-* replies for leaked paths. They pointed data-rebuild at a live table with NO pending change - data-migrate on it returned applied:[] - and expected it to say the same. It rebuilt: built the copy, copied the rows, dropped the original, renamed into place. Rows intact, macrons byte-identical, the page still rendering - they verified all of that before writing, which is why this is a finding and not an alarm. TWO THINGS FOLLOW, and one fix closes both: data-rebuild should be a NO-OP when the shapes already agree, the way data-migrate correctly is; and because nothing was lost, nothing was confirmed, so a stray or scripted rebuild replaces a production table with no prompt and no change to justify it. Making the no-op a no-op removes the thing that would have needed confirming. rebuild_table now consults plan_migration first and returns ok with noop:1 when there is nothing additive, nothing blocked, nothing to create and no column to drop - no safety export written either, since there is nothing to protect. A rebuild that DOES drop a column still asks and still runs, asserted in the same file so the guard cannot swallow real work. MINOR, SAME REPORT: data-tables carried public and pending_schema per table and data-table carried neither, so the reply for a published and an unpublished table was identical - and data-table is what somebody inspecting one table reaches for when asking why a page is empty. Now both answer. Three sabotages, all confirmed to fail t/unit/data/23."
---

# What happened

```datatable
columns: Call | Pending change | What it did
widths: 3.6cm | 3.4cm | X
bold: 1
tone: medium
---
`data-migrate` on `paintings` | none | `applied: []` -- correctly nothing
`data-rebuild` on `paintings` | none | built `paintings__rebuild`, copied 3 rows, dropped the original, renamed into place
```

Nothing was lost, so nothing was confirmed. That is the right rule for a
rebuild that drops no column. It is the wrong outcome for a rebuild that had
no reason to run: a production table was replaced with no prompt and no change
to justify it.

# One fix, both problems

Asking for a confirmation on every rebuild would add friction to the real
ones. Making the no-op a no-op removes the thing that would have needed
confirming. `rebuild_table` now consults the migration plan first, and when
there is nothing to add, nothing blocked, nothing to create and no column to
drop, it answers `ok` with `noop: 1` and touches nothing -- not even the safety
export, since there is nothing to protect.

# The minor half

`data-tables` reported `public` and `pending_schema` per table. `data-table`
reported neither, so the reply for a published and an unpublished table was
identical. The agent nearly filed *"you cannot tell whether a table is
published"* before checking the list endpoint -- and `data-table` is the one a
person inspecting a single table reaches for. Both answer now.
