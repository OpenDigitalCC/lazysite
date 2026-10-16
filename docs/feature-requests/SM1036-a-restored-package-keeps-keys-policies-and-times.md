---
id: SM1036
title: "SM1036: a restored site package keeps its rows' keys, policies and times"
subtitle: "A package could not restore a table whose key the store assigns, brought a personal row back shared, and dated every row at the restore. Each row now comes back as it was exported."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 P21, the open questions SM996 recorded; ruling of 2026-10-12
area: data
status-note: "SHIPPED (0.15.5): a package carries each row's times and policy beside its rows (the auto key was already in them); package_apply keeps the key (import_table keep_auto_key, insert_row auto_key =>), the times (times =>) and the policy, logs what it kept; lint 137 holds times/auto_key to the restore (t/unit/data/73)."
---

# The ruling

Found while building SM996 and recorded as its open questions. The release
manager ruled, in these words: "(1) restore auto-key tables, (2) keep
row_policy, (3) keep original timestamps" - a site-package restore restores
tables with an auto-generated key keeping each row's original key (the sequence
continues after the highest); personal rows are exported with their row_policy
and restored as personal to the same owner; created_at/updated_at come back as
exported (the restore recorded in audit and log). Older packages without these
fields keep today's behaviour.

# What was wrong

Measured with t/unit/data/73 before the change (every subtest failed):

1. **An auto-key table was not restored at all.** `export_table` writes the
   auto key into every row (rows may name each other by it), and
   `import_table` handed it to `coerce_row`, which refuses a supplied auto key
   from any writer ("'id' is assigned by the store and cannot be supplied"). The
   table landed in `data_skipped`.
2. **A personal row came back shared.** The export carries declared fields
   only; `row_policy` is the engine's column, so it did not travel, and a row
   with no policy is shared: any writer the table admits could amend it.
3. **Every row was dated at the restore.** `_stamp` wrote `created_at` and
   `updated_at` from the clock.

# What changed

**The package carries the times and the policy.** Beside `rows` and SM996's
`authors`, each keyed by the row's key: `times` (`created_at`, `updated_at`) on
a table with `timestamps: true`, and `policies` on a table with `row_policy:
true` - only the rows that carry one, since an absent policy means shared and
stays absent. Beside, not in, for SM996's reason: an older release's import
refuses an owned column in a row and ignores a key it does not know. The auto
key needed nothing new: it was always in the rows.

**The restore keeps them.**

- `import_table($d, $export, keep_auto_key => 1)` takes the auto key out
  before the coercion, refuses one that is not a positive whole number, and
  hands it back in the row. Without the option the import is what it was.
- `insert_row` takes `auto_key => N` (written at that key after the coercion,
  refused on a table whose key is not the store's) and `times => { created_at,
  updated_at }` (each absent, or a date and time the value layer reads,
  written as it normalises it). Both are refused without a non-empty actor,
  as `authors =>` is: the actor is who wrote the row into this store.
- `package_apply` asks for the key, puts the kept policy on the row (so the
  coercion checks it like a writer's: a table that does not declare
  `row_policy` refuses the row rather than restoring a personal row shared),
  and passes the authors, times and key.

The key is an INTEGER PRIMARY KEY's rowid (no AUTOINCREMENT), so the next row
the store assigns is one past the highest - the sequence continues without a
step of its own.

**Recorded.** The log line "table rows restored" and each `data_restored` entry
carry `keys_kept`, `authors_kept`, `times_kept` and `policies_kept` beside the
table, the rows and `user` (the applier); the surface's audit row for the apply
names the applier, as before.

**Older packages.** A package without `times` or `policies` restores its rows
at the time of the restore with no policy, as before, and one without `authors`
as the applier's (SM996). One change reaches an older package too: its export
already carried the auto key, so an auto-key table it holds is now restored at
its keys where it was skipped before - the ruling's (1).

**Lint 137** holds `times =>` and `auto_key =>` to the one restore, as it
holds `authors =>`: what a row says about itself is the caller's word.

# Tests

t/unit/data/73: a source table (auto key, timestamps, row_policy) with a
personal row by alice, a shared row by bob, an unmarked row by carol, a deleted
row leaving a gap in the keys, and timestamps set in the past. Applied by dora:
each row keeps its key and the next insert takes one past the highest; the
personal row is personal and alice's, bob cannot amend it and alice can; the
shared row is shared and the unmarked one unmarked; every `created_at` and
`updated_at` is as exported; the log and `data_restored` name the counts and
dora. The same package with the side maps removed restores its rows as dora's,
now, with no policy. `import_table` without the option refuses the key, with it
keeps it, and refuses zero, a negative and a non-number. `insert_row` refuses
times or a key without an actor, four bad shapes of times, four bad keys, and a
key on a natural-key table, writing nothing; a good pair and key are written.
t/unit/data/70 and 13 and the site-package tests pass.

Sabotage (tmp/sab-bak/P21-restore/, restored by cp, checked by cmp), each
failing 73: the apply not asking for the key (subtests 1-5); the policies not
exported (2, 4, 5); the times stamped now (3, 7); times taken without an actor;
a key taken on a natural-key table; an imported key not checked; the kept
policy not put on the row. Lint 137 names a second caller passing `times =>` or
`auto_key =>`.
