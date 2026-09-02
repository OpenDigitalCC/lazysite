---
id: SM742
title: "SM742: a constraint failure reads as prose, not as driver text"
subtitle: "SM713 stopped data errors naming the server. What survives the cleaner is still the driver's own sentence - 'UNIQUE constraint failed: table.column' - which is not a leak, but is the database talking to the caller in its own voice."
brand: plain
standard-margins: true
status: open
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
