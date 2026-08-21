---
title: "SM447: the typed data core - descriptors, adapter, connection, values"
subtitle: "DP-1 of the SM410 map. A declared schema, one place that decides what a value means, and a render path that holds a handle it cannot write through."
brand: plain
standard-margins: true
status: partial
status-note: "DEPARTURE FROM THE SM410 MAP, FLAGGED FOR THE RELEASE MANAGER: the map lists 'schema-state via the SM404 checked writer'. Built without a state file. A state file is a THIRD copy of the truth after the descriptor (what is wanted) and the database (what exists), and the failure is concrete rather than theoretical - DP-6 restores rows into a FRESH database, possibly on another engine, so a state file arrives describing something that is not there; and restoring data.sqlite alone leaves two files disagreeing with no way to tell which is right. Deriving the state costs one PRAGMA and cannot desync, because the actual state IS the database. What a state file would have added - when a migration ran and who ran it - is audit-trail material and the audit trail already exists. SM404's checked writer remains right for anything that does write a file. TWO ENGINE LIMITS, MEASURED AND ASSERTED, shape the migration design: ALTER TABLE ADD COLUMN NOT NULL is refused once the table holds rows and accepted while it is empty, so emitting it would produce a migration that works on an unused site and fails on a used one; and DEFAULT ? is a syntax error, so a DDL default cannot be bound. Therefore a new field is added as a NULLABLE column plus a BOUND backfill scoped to IS NULL, and required-ness is enforced in Value.pm on write - which is the existing decision that validation does not live in DDL, reached from the other direction. FILED 2026-08-21, retrospectively, because the work started from the SM410 plan rather than from a field report and no filing was written - which t/lint/26, widened the same day to see qualified bullets, would have caught the moment a changelog entry claimed it. THIS IS DP-1 OF SM410, not a separate proposal: the map, the boundary and the two corrected spec claims live there and are not retyped here. WHAT IS BUILT: Descriptor.pm (YAML::PP load, validate, REJECT), SQLite.pm (DDL generation, typed column mapping), Connect.pm (two handles, the render path cannot write), Value.pm (write-side coercion, defaults, reject-not-repair). WHAT REMAINS IN DP-1: DML generation, schema state via the SM404 checked writer, additive migrations, the canonical typed-JSON serialiser hoisted for DP-6, the MCP tool set, manage_data across the nine parity points (t/lint 14, 19, 23, 32, 35, 36, 57, 58, 71), and ADR 0009's contract shape. THE DIVISION THE WHOLE THING RESTS ON is stated in SQLite.pm's header and asserted in its tests: VALUES ARE BOUND, always, everywhere - so a value containing SQL metacharacters is stored and returned verbatim because it never reaches the parser as syntax; IDENTIFIERS cannot be bound, so they are interpolated, and the only reason that is safe is that Descriptor.pm has already refused anything outside [a-z][a-z0-9_]*. That check runs once at load and _ident() re-asserts it at the point of interpolation anyway, because an assumption that is free to check is not worth carrying. TWO TYPE MAPPINGS EXIST TO PREVENT A SPECIFIC BUG and are pinned by test: decimal is TEXT and never REAL, because SQLite's REAL is a double and money in a double is the bug the type exists to prevent; boolean is INTEGER 0/1 normalised on write, because SQLite has no boolean and accepting 'true' into a TEXT column would make the round-trip depend on how it was written. VALIDATION IS NOT IN DDL, deliberately: defaults, ranges, enum membership and calendar checks are applied in Value.pm so that ONE implementation decides them for every engine rather than each engine's dialect deciding differently - and so that no value ever reaches generated SQL text. NOT STARTED AND HELD: everything from DP-2 onward, and the release manager is holding the whole feature back from the beta line while the field findings settle."
---

# What is built

```datatable
columns: Module | Answers
widths: 5cm | X
bold: 1
tone: medium
---
`Descriptor.pm` | is this schema legal, and what exactly did it declare
`SQLite.pm` | what SQL creates that, and what column type holds each field
`Connect.pm` | which handle may write, and which may only read
`Value.pm` | is this value correct, and what is its canonical form
```

# The division everything rests on

Values are **bound**, always. A value carrying SQL metacharacters is stored
and returned byte for byte, because it never reaches the parser as syntax.
Identifiers **cannot** be bound -- SQL has no placeholder for a table or column
name -- so they are interpolated, and the only thing that makes that safe is
that the descriptor loader has already refused anything outside
`[a-z][a-z0-9_]*`.

That is why the loader **rejects** rather than warns. A warning would leave a
name in play that the generator is entitled to trust.

# Why validation is not in the DDL

Every engine's DDL dialect would then decide, separately, what a default is,
what a boolean accepts, and whether a date is real. Those answers must not
vary between engines, so one implementation makes them -- and keeping them out
of DDL also keeps values out of generated SQL text, which is the invariant
above.

The cost is that the store will accept a hand-written `INSERT` the plugin
would refuse. That is accepted: the plugin is the interface, and a hand-edited
SQLite file was never inside the guarantee.

# Reject, do not repair

`12.345` into a `places=2` column is refused, not rounded. A store that
silently rounds money is worse than one that will not take it -- the caller
learns nothing, and the difference surfaces later as a discrepancy in a total
nobody can reconcile.

The same reasoning covers the smaller cases: an unknown field name is refused
rather than dropped, because dropping it makes a typo look like a successful
write.
