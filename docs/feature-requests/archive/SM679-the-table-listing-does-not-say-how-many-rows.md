---
title: "SM679: the table listing says what a table is called and not how big it is"
subtitle: "Release manager, 2026-08-28: 'data tables - on list of tables, add count of rows on the listing'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). The table listing carries `row_count`, counted in the pass that already opened the handle and read each descriptor. UNKNOWN IS NOT ZERO: a table awaiting migration, or one whose count fails, omits the field entirely rather than reporting 0 - an operator deciding whether an import worked reads 0 rows as failure, and the honest answer is that nobody could tell. The count uses SQLite::count_sql rather than a hand-built statement, because that owns identifier quoting for a table name. Sabotage-verified three ways."
---

# What the listing carries

`action_data_tables` returns, per table: `table`, `title`, `domain` when bound,
`public`, and `pending_schema` when the declared shape has drifted from the
stored one. There is no row count, so the Data page cannot show one.

A count is the first thing anybody wants from a list of tables: which of these
has anything in it, which is the big one, did the import land. Without it the
listing answers "what tables exist" and nothing about their state.

`row_count` already exists as a field name in this module - `action_data_safety_
export_read` returns one for an export file - so the listing would be using the
established name rather than inventing one.

# The one thing to get right

A count per table is a query per table. On a listing that already opens the
database and reads each descriptor that is cheap, and SQLite counts a small
table instantly - but it is a cost that grows with the NUMBER of tables, on a
page that loads every time somebody opens Data.

So: count in the same pass that already reads each descriptor, not in a second
loop, and treat an unreadable table as unknown rather than zero. A table whose
descriptor failed already returns `ok => 0` and should carry no count at all -
reporting `0` for a table that could not be read is the kind of confident wrong
answer this project keeps filing against.

# Related

[[SM678]] (permissions on the same listing - both are things the Data page
cannot currently say about a table), SM447 (the typed data core this listing
serves).

# Not started
