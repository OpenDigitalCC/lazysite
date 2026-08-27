---
title: "SM487: the rebuild pre-flight named a risk that was not the one that bit"
subtitle: "It warned about losing a column, the operator confirmed, and the rebuild failed on a row that could not satisfy a tightened constraint - with a driver string naming an internal table and no row"
brand: plain
standard-margins: true
status: shipped
status-note: "FROM THE FIELD AGENT'S REBUILD SESSION on 0.10.26, reported as two notes on a feature that otherwise 'works well'. They rebuilt a throwaway table whose new descriptor dropped `note` and made `when` required. The pre-flight said 'this rebuild drops note - confirm by naming it'; they confirmed; the rebuild FAILED and rolled back on a row with no `when`, and the failure read 'DBD::SQLite::db do failed: NOT NULL constraint failed: rebuild_probe__rebuild.when' - an internal table, no row. TWO DEFECTS IN ONE SESSION, and they compound: a confirmation that names a risk which is not the one that bites trains an operator to confirm without reading, and the failure that does bite then speaks the driver's language. THE PRE-FLIGHT ONLY CONSIDERED DROPPED COLUMNS. It never asked whether the rows that SURVIVE can satisfy the NEW constraints. Now, for every carried column: required with NULLs present is counted and reported ('2 rows have no when'); unique with a repeated value names the value; a narrowed type pulls the distinct stored values out and runs each through Value.pm, because only Value.pm can judge whether 'ten' is an integer. A BLOCKED REBUILD IS REFUSED BEFORE CONFIRMATION IS ASKED - no confirmation can fix data, and asking for one first is a prompt about the wrong thing. THE DRIVER STRING NO LONGER REACHES THE OPERATOR: what the pre-flight can predict it refuses up front; what it cannot (a required column that is NEW, so not carried, on a populated table) is translated into the pre-flight's own language with the raw text kept for the log. Five sabotages, all confirmed to fail t/unit/data/22, which replays the field session verbatim."
---

# The session that found it

```datatable
columns: Step | What happened
widths: 6cm | X
bold: 1
tone: medium
---
New descriptor: drop `note`, make `when` required | pre-flight: *"this rebuild drops note - confirm by naming it"*
Operator confirms `note` | rebuild runs
Row with no `when` | **rebuild fails**, rolls back cleanly
The error | `NOT NULL constraint failed: rebuild_probe__rebuild.when`
```

The pre-flight was correct about `note` and silent about `when`. The failure
named an internal table and no row. Neither message told the operator what to
do, and between them they cost a confirmation and a rollback to learn one
fact: *two rows have no `when`*.

# What the pre-flight checks now

For every column the rebuild **carries**, what the existing rows would do
against the **new** constraint:

```datatable
columns: Tightening | Checked how | Reported as
widths: 3.4cm | 6cm | X
bold: 1
tone: medium
---
`required` | count of NULLs | *"2 rows have no 'when'"*
`unique` | first repeated value | *"the value 'x' is in more than one row"*
narrowed type | each distinct value through `Value.pm` | *"stored values will not convert: 'ten'"*
```

The third cannot be asked of the database. Whether `"ten"` is a valid integer
is `Value.pm`'s question, so the values come out and go through the same
coercion a live write would.

# Blocked comes before confirm

A rebuild with a blocked column is refused **before** it asks which columns
the operator accepts losing. No confirmation can fix data, and asking for one
first produces exactly the session above: a confirmation given in good faith
about a risk that was never going to be the problem.

# The driver's sentence

Everything the pre-flight can predict, it refuses up front. What it cannot --
a column that is both **new** and required on a populated table, which no
check on carried columns can see -- is translated into the pre-flight's own
words, and the raw driver text goes to the log where it belongs.
