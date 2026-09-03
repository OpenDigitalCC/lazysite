---
id: SM742
title: "SM742: a constraint failure reads as prose, not as driver text"
subtitle: "SM713 stopped data errors naming the server. What survives the cleaner is still the driver's own sentence - 'UNIQUE constraint failed: table.column' - which is not a leak, but is the database talking to the caller in its own voice."
brand: plain
standard-margins: true
status: shipped
---

# The moment this fills

SM713 put `_clean_db_error()` in front of ten client-facing error sites. It
strips the file and line, and the `DBD::` driver vocabulary, then passes the rest
through.

The field agent checked a duplicate key on 0.12.0 and got:

> `table 'v12probe': the insert failed - UNIQUE constraint failed: v12probe.code`

**No path, no `DBD::`, no server detail.** SM713 does what it claims. They noted
it anyway, correctly: this is raw SQLite phrasing where "no such table" (11T-04)
came back as clean prose. The set is inconsistent.

# Why it is worth levelling up

Not for prettiness.

**The wording is the driver's, so it is not ours to rely on.** "UNIQUE constraint
failed: table.column" is SQLite's sentence and SQLite's format. Anything a caller
builds against it - a form that wants to highlight the offending field, an
importer that wants to say which row collided - is parsing text that belongs to a
dependency. The moment the backend changes, or SQLite rewords, every such caller
breaks silently.

**And the caller can act on this one.** A unique-constraint failure names the
caller's own table and column, which is exactly the information a form needs to
point at the right field. Passing it through as an opaque sentence wastes
structure we already have.

# What would fix it

Map the small set of constraint classes onto prose, and keep the parts, not just
the string. The classes worth naming:

- **UNIQUE** - "a row with this `<column>` already exists".
- **NOT NULL** - "`<column>` is required".
- **FOREIGN KEY** - "`<column>` refers to a row that does not exist".
- **CHECK** - "`<column>` is outside the values this table allows".

Anything unrecognised keeps today's behaviour: cleaned by `_clean_db_error` and
passed through. **The fallback matters more than the mapping** - a cleaner that
recognises four shapes and mangles the fifth is worse than one that recognises
none.

Where an error names a column, returning it as a field alongside the message
would let a form highlight it without parsing prose - ours or SQLite's.


# What shipped

`_constraint_error` recognises four shapes and returns a sentence plus, where
the driver named one, the column. `_clean_db_error` consults it first and falls
through to SM713's general cleaning for everything else. The three ROW-WRITE
sites - insert, update, delete - additionally carry `field`, because those are
the ones a form reaches and a form is the thing that can act on knowing which
input was refused.

| Driver | Ours |
| --- | --- |
| `UNIQUE constraint failed: products.code` | a row with this code already exists |
| `UNIQUE constraint failed: stock.product, stock.location` | a row with this combination of product and location already exists |
| `NOT NULL constraint failed: orders.customer` | customer is required |
| `FOREIGN KEY constraint failed` | this refers to a row that does not exist |
| `CHECK constraint failed: items.quantity` | quantity is outside the values this table allows |
| `CHECK constraint failed: positive_total` | the value breaks the table's 'positive_total' rule |

## Three decisions inside it

**A composite key says COMBINATION.** Naming only the first of two columns
would send an author to fix a field that is not, by itself, the problem.

**FOREIGN KEY claims no column.** SQLite does not say which key failed, and a
guess pointed at a field is worse than no field: the author edits the wrong
input and sees the same error again.

**The table prefix is the discriminator, and it is required.** SQLite writes
`table.column` when a constraint concerns a column and a BARE NAME when a CHECK
is named for itself - so `positive_total` is a rule's name, not a field. Without
that rule the two strings are identical, and the first version reported
`positive_total` as a column: a form would have highlighted an input that does
not exist. A driver emitting bare column names would lose them here and fall
through to the general cleaner, which is the safe direction to be wrong in.

## What the test protects

The **fallback**, as carefully as the mapping. `no such table: widgets` and
`database is locked` must arrive exactly as SM713 left them, `undef` and `''`
must still answer something showable, and a row whose CONTENT mentions a
constraint must not be rewritten as though it failed one.

## A bug the test caught

The first version captured to end of line, which swallowed the driver's
` at <path> line N` suffix - so `products.code at /home/.../Tables.pm line 572`
parsed as no column, every shape fell through, and the cleaner emitted SQLite's
sentence unchanged while looking like it had deliberately translated nothing.
The file and line are now stripped before matching.
# Could a lint have caught it

No, and worth saying so plainly: `t/lint/112` checks that a caller-facing error
does not interpolate a path, a driver prefix or an echoed command. This message
does none of those. It passes, and should.

"Is this sentence ours or a dependency's" is not a property a static check can
see. It took a person reading two error messages from the same subsystem and
noticing they did not sound like they came from the same program.

# Provenance

Edge testing agent, 0.12.0 stable pass, V12-04. Filed as a note on a PASS rather
than as a defect, which is the right weight for it.
