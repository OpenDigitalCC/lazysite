---
title: "SM447: the typed data core - descriptors, adapter, connection, values"
subtitle: "DP-1 of the SM410 map. A declared schema, one place that decides what a value means, and a render path that holds a handle it cannot write through."
brand: plain
standard-margins: true
status: partial
status-note: "EXPORT FORMAT, and the measurement that decided it: encoding 10.50 as a JSON NUMBER and decoding it returns 10.5 - the trailing zero is gone because it went through a double, which is the exact bug the decimal type exists to prevent. So decimal is exported as a STRING, and that is asserted rather than commented. Boolean uses JSON's own true/false rather than SQLite's 0/1 storage, NULL and empty string stay distinct, and the output is canonical (sorted keys, rows ordered by key) so two exports of the same data are byte-identical - a backup nobody can diff is a backup nobody checks. The declared shape travels with the data and an import REFUSES a file whose shape differs from the descriptor it is going into: coercing across a shape change would be a migration performed silently, by the one operation an operator runs when something has already gone wrong. Imported rows go through the SAME coercion as a live write, so a restore cannot put anything into the store that a write could not. DEPARTURE FROM THE SM410 MAP, FLAGGED FOR THE RELEASE MANAGER: the map lists 'schema-state via the SM404 checked writer'. Built without a state file. A state file is a THIRD copy of the truth after the descriptor (what is wanted) and the database (what exists), and the failure is concrete rather than theoretical - DP-6 restores rows into a FRESH database, possibly on another engine, so a state file arrives describing something that is not there; and restoring data.sqlite alone leaves two files disagreeing with no way to tell which is right. Deriving the state costs one PRAGMA and cannot desync, because the actual state IS the database. What a state file would have added - when a migration ran and who ran it - is audit-trail material and the audit trail already exists. SM404's checked writer remains right for anything that does write a file. TWO ENGINE LIMITS, MEASURED AND ASSERTED, shape the migration design: ALTER TABLE ADD COLUMN NOT NULL is refused once the table holds rows and accepted while it is empty, so emitting it would produce a migration that works on an unused site and fails on a used one; and DEFAULT ? is a syntax error, so a DDL default cannot be bound. Therefore a new field is added as a NULLABLE column plus a BOUND backfill scoped to IS NULL, and required-ness is enforced in Value.pm on write - which is the existing decision that validation does not live in DDL, reached from the other direction. FILED 2026-08-21, retrospectively, because the work started from the SM410 plan rather than from a field report and no filing was written - which t/lint/26, widened the same day to see qualified bullets, would have caught the moment a changelog entry claimed it. THIS IS DP-1 OF SM410, not a separate proposal: the map, the boundary and the two corrected spec claims live there and are not retyped here. WHAT IS BUILT: Descriptor.pm (YAML::PP load, validate, REJECT), SQLite.pm (DDL generation, typed column mapping), Connect.pm (two handles, the render path cannot write), Value.pm (write-side coercion, defaults, reject-not-repair). WHAT REMAINS IN DP-1: the MCP tool set, manage_data across the nine parity points (t/lint 14, 19, 23, 32, 35, 36, 57, 58, 71), and ADR 0009's contract shape. THE DIVISION THE WHOLE THING RESTS ON is stated in SQLite.pm's header and asserted in its tests: VALUES ARE BOUND, always, everywhere - so a value containing SQL metacharacters is stored and returned verbatim because it never reaches the parser as syntax; IDENTIFIERS cannot be bound, so they are interpolated, and the only reason that is safe is that Descriptor.pm has already refused anything outside [a-z][a-z0-9_]*. That check runs once at load and _ident() re-asserts it at the point of interpolation anyway, because an assumption that is free to check is not worth carrying. TWO TYPE MAPPINGS EXIST TO PREVENT A SPECIFIC BUG and are pinned by test: decimal is TEXT and never REAL, because SQLite's REAL is a double and money in a double is the bug the type exists to prevent; boolean is INTEGER 0/1 normalised on write, because SQLite has no boolean and accepting 'true' into a TEXT column would make the round-trip depend on how it was written. VALIDATION IS NOT IN DDL, deliberately: defaults, ranges, enum membership and calendar checks are applied in Value.pm so that ONE implementation decides them for every engine rather than each engine's dialect deciding differently - and so that no value ever reaches generated SQL text. NOT STARTED AND HELD: everything from DP-2 onward, and the release manager is holding the whole feature back from the beta line while the field findings settle."
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

# Decisions for the release manager

Collected while building DP-1. Nothing here is blocking today's work; each is
a point where I chose, and the choice is reversible.

```datatable
columns: Ref | Decision | What I did, and why
widths: 1.4cm | 4.5cm | X
bold: 1
tone: medium
---
D1 | Three new runtime dependencies | `DBI`, `DBD::SQLite`, `YAML::PP` were absent from `sbom-deps.json` entirely, so the release gate would have failed once this code shipped. Declared, with Debian/RHEL/Alpine package names. This is the first time lazysite would require a database driver at all.
D2 | RESOLVED - derivation, confirmed | The release manager chose derivation over the SM410 map's state file. A state file is a third copy of one fact, after the descriptor and the database, and the only copy nobody validates: DP-6 restores into a **fresh** database so a copied file describes something absent; a partial restore leaves two files disagreeing with nothing able to arbitrate; a hand-edited store moves on while the file does not. What derivation cannot answer - what the shape *was*, when it changed, who changed it - is filed as **SM468** to be considered later, and would be a TABLE in the store rather than a file beside it.
D3 | Money is refused, never rounded | `12.345` into a `places=2` column fails rather than rounding. A store that silently rounds money is worse than one that will not take it.
D4 | Required-ness is not a column constraint | `ADD COLUMN ... NOT NULL` is refused by SQLite once rows exist and accepted while empty, so emitting it gives a migration that works on an unused site and fails on a used one. Required is enforced on write, in `Value.pm`.
D5 | Destructive changes are named, not performed | Type changes, tightening to `NOT NULL`, and dropping a column are reported and refused. DP-5 builds the confirmation flow; this layer will not do them behind a flag.
D6 | Blocked items do not freeze safe ones | A migration plan applies what is safe and reports the rest. All-or-nothing makes one awkward column block every other change, and the usual response to that is hand-editing the store.
D7 | Empty string is absence, except for text | A cleared number becomes NULL rather than `0`; a cleared text field keeps its empty string. Storing `0` invents data the operator did not enter.
D8 | Decimal exports as a JSON string | Measured: `10.50` encoded as a JSON number decodes to `10.5`. Money as a number would lose precision during a **restore**, and look plausible doing it.
D9 | A restore refuses a changed shape | Missing column, extra column, changed type: refused, not coerced. Coercing across a shape change is a migration performed silently, by the operation an operator runs when something has already gone wrong.
D10 | `YAML::PP`, not `YAML::XS` | Pure Perl. The descriptors are small, and it is one fewer compiled dependency on the rare architectures v1 still supports.
D11 | RESOLVED - SQLite first, a second engine is an ADDITION | Confirmed by audit rather than intent, and the audit found one leak: `Tables.pm` called `$dbh->last_insert_id` directly - a DBI method whose arguments differ by driver, so exactly the difference that surfaces only once a second engine exists. Moved behind `last_insert_key()`. `t/unit/data/12` now names the adapter pair (`SQLite.pm`, `Connect.pm`) and fails if any other module contains a PRAGMA, a driver DSN, a `DBD::` class, `last_insert_id`, `journal_mode`, `AUTOINCREMENT` or a `sqlite_*` attribute. Comments are exempt - the reasoning belongs beside the code; what must not appear is a construct that RUNS. DP-7 is now one new module plus a connector.
D13 | Plugin declarations are validated where they are read | ADR 0009 has the platform consume `owns` instead of knowing a plugin by name, so four consumers each trust the list. Trust established four times is correctly established zero to three times. Validated once, in `Lazysite::Plugins::Owns`, before any consumer exists.
D14 | `storage` may name a subtree of `lazysite/`, never the tree | A site package excludes `lazysite/` because the auth store, sessions and backups live there. A plugin claims a NAMED subtree, must end in `/` so it cannot prefix-match a sibling, and cannot traverse or be absolute. Otherwise a feature that ships a site becomes one that ships an auth store.
D15 | RESOLVED - a store that cannot be read says why | **My first report of this was wrong and the correction matters.** SQLite does not fail silently: it raises *attempt to write a readonly database*, because a WAL reader must create a `-shm` file beside the database. The silence was OURS - `read_rows` wrapped the schema probe in `eval {} || { exists => 0 }`, so a raised error became *the table has not been created yet*. The engine reported accurately and our fallback discarded it. Now `store_diagnosis()` probes with a real write and the read path names the cause, so a read-only deployment is distinguishable from an empty table.
D12 | Listings are capped at 1000 | `LIMIT` is always present and bound; a caller may raise the default 200 but cannot remove the ceiling.
```

## Still open, and genuinely yours

**DP-7** - whether Postgres or MySQL adapters are ever built. Nothing in the
design prevents it and nothing so far needs it.

**DM-4's CSV rules** - the manager brief specifies a staged
validate/diff/confirm import. What a CSV column *means* when it does not match
a declared type is the open question, and the answer this layer would prefer
is *refuse the row and say which*, consistent with D3 and D9.
