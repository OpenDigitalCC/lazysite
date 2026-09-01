---
id: SM725
title: "SM725: a named-key table declaring timestamps could not be created"
subtitle: "The generated DDL put the timestamp columns after the table-level PRIMARY KEY clause, which SQL does not allow. It failed only on the named-key path, which is why it survived since the option shipped."
brand: plain
standard-margins: true
status: shipped
---

# What happened

Reported by the jpm data agent, 2026-09-01, from
`jpm-stock-correction.explore.lazysite.io`. A descriptor with `timestamps: true`
and a **named** key failed at migrate:

```
create failed - DBD::SQLite::db do failed: near "created_at": syntax error
```

The same option on a table with an **automatic** key worked. The reporter said
"looks like the generated CREATE emits the timestamp columns differently on the
named-key path", which is exactly right.

# The cause

`create_table_sql` built its column list in this order: the key column (auto
only), the fields, **the `PRIMARY KEY (...)` table constraint**, then the
timestamp columns. So a named-key table produced:

```sql
CREATE TABLE IF NOT EXISTS "t_demo" (
  "delivery" TEXT NOT NULL,
  "qty" INTEGER,
  PRIMARY KEY ("delivery"),
  created_at TEXT,          -- a column definition AFTER a table constraint
  updated_at TEXT
)
```

**A table constraint must follow every column definition.** SQLite refuses this,
naming the first token it did not expect - `created_at` - which is why the error
points at the timestamps rather than at the ordering.

## Why only the named-key path

An auto key emits `id INTEGER PRIMARY KEY` **inline on the column**. That is a
column constraint, not a table constraint, so nothing has to come after it and
appending the timestamps is harmless.

A named key has no column to hang the constraint on, so it is emitted as a
table-level clause - and only then does the ordering matter. That is why the
reporting site had one table of each shape with only one of them refusing, and
why this survived from the day the option shipped.

# The fix

Emit the timestamp columns **before** the table constraint. Two blocks swapped.

# Why no test caught it

There was no test that generated DDL for a named-key descriptor with timestamps
and **executed** it. `t/unit/data/50` now does, for three shapes - named key
with timestamps, auto key with timestamps, named key without - and hands each
statement to a real SQLite handle rather than comparing it against expected
text.

That distinction is the point. The defect was that valid-*looking* SQL was
invalid, so a string comparison written from the same misunderstanding would
have agreed with the bug. Sabotage-verified: reverting the fix fails five
assertions.

# Not changed

The reporter's workaround - plain `entered_at` text fields instead of
`timestamps: true` - needs no undoing. A descriptor can be switched back to
`timestamps: true` on a new table; an existing table would need a migration,
which is the operator's call rather than something this fix performs.
