---
id: SM996
title: "SM996: a restored site package keeps its rows' authors"
subtitle: "SM989 stamped every restored row with the account that applied the package. The release manager ruled the rows keep the authors they were exported with, and the applier is what the audit records."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 P21, ruling of 2026-10-12 ("Keep original authors")
area: data
status-note: "SHIPPED (PENDING): a package carries created_by/updated_by beside a timestamped table's rows and package_apply keeps them through insert_row's `authors =>`, beside `actor =>` (the applier); lint 137 confines `authors =>` to the restore (t/unit/data/70)."
---

# The ruling

"Keep original authors": a restored site package's rows keep the
created_by/updated_by they were exported with (change n398's behaviour); the
audit trail records who applied the package. Lint 137 must still pass (it
requires `actor =>`).

# What changed

**The package carries the authors.** For a table with `timestamps: true`,
`package_create` adds `authors` to the table's export: the row's key mapped to
its `created_by` and `updated_by`. It sits beside `rows`, not in them, because
an older release's `import_table` refuses a stamped column in a row and ignores
a key it does not know.

**The restore keeps them.** `package_apply` passes each row's pair to
`Lazysite::Data::Tables::insert_row` as `authors =>`, and `_stamp` writes those
instead of the actor. `created_at`/`updated_at` are the time of the restore, as
before (the ruling names the authors only).

**How a restore names "keep the exported authors" (lint 137).** The call still
passes `actor => $auth_user`, the account applying the package: the actor is
who wrote the row into this store, the authors are who the row says wrote it.
`insert_row` refuses `authors =>` without a non-empty actor, so the rule "every
stamping call names its actor" keeps meaning something on the restore. Lint 137
gains a second assertion: `authors =>` appears on exactly one call, the
restore in Manager::SitePackage. Every other write is stamped from the identity
its surface verified, and a new caller cannot choose authors without the lint
naming it.

**What an author may be.** Absent (undef or empty: written anonymously, kept
anonymous) or a plain string of at most 254 characters with no control
characters. A mapping with any other key, a reference, or a longer or
control-bearing value refuses the row. A package is a file that travelled; the
applier holds the site-apply grant, and the authors it carries are taken as
that grant's to restore, recorded against the applier.

**Who applied it.** The log line "table rows restored" names the table, the
rows, `authors_kept` and `user` (the applier), and the surface's audit row for
the apply action names the applier as before. `data_restored` entries gain
`authors_kept`.

A package built before this carries no authors: its rows are stamped as the
applier's, as SM989 did and as a CSV import stamps the importer.

# Found while building it (not changed)

- **A site package cannot restore an auto-key table.** `export_table` carries
  the auto key (rows may reference each other by it), and `import_table` passes
  it to `coerce_row`, which refuses a supplied auto key ("'id' is assigned by
  the store and cannot be supplied"). The apply reports the table in
  `data_skipped`. Measured with a probe on this branch. Open question in
  WORK-PLAN-0154.
- **A personal row is restored as shared.** The export carries declared fields
  only, so `row_policy` does not travel: a row that was `personal` arrives with
  no policy, which means shared, and any writer the table admits may amend it.
  Pre-existing; not widened here. Open question in WORK-PLAN-0154.

Ruled 2026-10-12, "(1) restore auto-key tables, (2) keep row_policy, (3) keep
original timestamps", and built as SM1036: a restore keeps each row's auto key,
its policy and its `created_at`/`updated_at` as exported.

# Tests

t/unit/data/70: a package built from rows by alice, bob (updated by dora) and
an anonymous form, applied by carol, keeps all four authors and logs carol and
`authors_kept=3`; a package from a table without timestamps restores as the
applier; `authors =>` without an actor, with an empty actor, and five bad shapes
are refused and write nothing; a good pair is written as the authors. Lint 137
holds `authors =>` to the one call. t/unit/data/13 passes.
