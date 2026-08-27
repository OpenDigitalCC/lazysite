---
title: "SM480: a table could be declared from three surfaces and removed from none"
subtitle: "Found by a field agent tidying up after a testing session. Every table they had created was going to outlive the testing"
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND THE WAY GAPS LIKE THIS ALWAYS ARE - somebody finished a session and tried to tidy up after themselves. There is no data-table-drop, no data-table-delete, no MCP tool, and the descriptor lives under lazysite/ where every write channel refuses on purpose, so there was no manual route either. Rows could be deleted one at a time; the table could not be removed at all. The consequence is not inconvenience: a table declared by mistake, misnamed, or made for one afternoon was PERMANENT. SHIPPED as data-table-drop and drop_data_table. IT TAKES EVERYTHING, so it asks first, and the confirmation is the table's own NAME rather than a yes - somebody who types the name has read the name, where somebody who clicks yes may not have read which table they were on. Case-sensitive, because a near-miss confirmation is not a confirmation. THE SAFETY EXPORT COMES FIRST AND A FAILURE TO WRITE IT STOPS THE DROP: the table is not recoverable, the data is, and an export that failed while the drop proceeded would leave an operator who was promised a copy with neither. Three guards cover that, and the test only fails when all three are removed - which is how I confirmed it covers the property rather than one branch of it. THE DESCRIPTOR GOES LAST: if the store drops and the descriptor survives, the table reads as declared-but-never-migrated, an ordinary recoverable state, where the other order leaves rows in a store nothing describes. ALSO FIXED HERE, from the same report: safety_export returned an ABSOLUTE server path - /home/<account>/web/<domain>/... - handing over the hosting account name and the server's filesystem layout, both guessable for the next site, and the same disclosure class as SM463's manager edit link. Site-relative now, for the rebuild as well as the drop. FILED RETROSPECTIVELY on 2026-08-23: the work was done first and the filing written after, which t/lint/26 would have caught the moment a changelog entry claimed it."
---

# What could not be done

```datatable
columns: Operation | Surfaces that could do it
widths: 6cm | X
bold: 1
tone: medium
---
Declare a table | control API, MCP, manager
Add a row | control API, MCP, a form
Delete a row | control API, MCP
**Remove a table** | **none**
```

The descriptor lives under `lazysite/`, which every write channel refuses by
design -- so there was no route round it either. A mistake was permanent.

# The confirmation is the name

`confirm` must be the table's own name, exactly. Somebody who types it has read
it; somebody clicking **yes** may not have read which table they were on. That
is the shape DP-5 already uses for a destructive migration, for the same
reason.

# The order matters

1. **Export first.** If it cannot be written, nothing is dropped.
2. **The stored table.**
3. **The descriptor last.** A store dropped with the descriptor surviving reads
   as declared-but-never-migrated -- ordinary, and recoverable. The other order
   leaves rows in a store nothing describes, which nothing in this system can
   read or clean up.

# The path it reports

Site-relative. It returned an absolute one, which handed over the hosting
account name and the server's filesystem layout to anyone holding the grant --
and an operator has no use for it, since they reach the file through Files,
which is rooted at the site. Fixed for the rebuild export at the same time,
which had the same defect and more users.
