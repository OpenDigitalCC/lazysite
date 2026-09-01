---
id: SM717
title: "SM717: seeded rows carry their own provenance, and demonstration data stays deleted"
subtitle: "Phase 3 of the apps portability plan. Two classes of seed data, stable keys on the rows rather than a record in the register, and a preview before anything is written."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 3 of 8.** Depends on SM715 (the manifest declares the classes and the
reserved columns) and SM716 (the register records that seeding ran). Phase 5
depends on this.

# What this phase delivers

## Two classes, declared separately

reference
: Rows the app's logic depends on - statuses, categories, units. **Restored
  when absent**, because the app breaks without them.

example
: Demonstration rows that make a fresh install look alive. **Seeded once.
  Deleted by the operator means deleted; no update may resurrect them.**

Conflating the two produces either resurrecting demo data or operators deleting
rows the app needs. The manifest declares them separately for that reason
alone.

## The record lives on the rows

Every seeded row carries an author-assigned stable key, not an auto-increment
id, plus the two reserved columns from SM715: the seed key and the app version
that introduced the row.

**The record of what was seeded lives on the rows, not in the register.** Rows
survive uninstall and travel through backup, export and fork migration with
their provenance intact; a register-side record would strip migrated rows of
their history. The register records only that seeding ran and when.

## When it runs

**At install, never on first request.** CGI first-run seeding races concurrent
visitors, and an install-time act can be previewed.

The preview follows the `install.pl --dry-run` shape: rows to add, rows to
refresh, **rows left alone because the operator changed them**.

## Bulk data

May live in a CSV or JSON file named by the manifest instead of inline rows.
Same loader, same stable-key rule, same behaviour - the file is where the rows
live, not a second path. A size cap applies; above it the data is the
operator's to import, not the app's to ship.

# Before building the loader

**Check whether an operator-facing import already exists** beside
`Lazysite::Data::Export` and reuse it. SM578's ruling applies: a rule copied
twice will disagree with itself. If one exists, this phase is mostly wiring; if
not, build it so the operator-facing import and the seed loader are the same
code path from the start.

# Open items - the operator decides

- **The bulk-seed size cap** (a number).
- **Whether that operator-facing import exists.** This is a question to answer
  before estimating the phase, not during it.

# Outcome test

- A fresh install seeds both classes; the preview named exactly what it then did.
- An operator deletes an example row; an update does **not** bring it back.
- An operator deletes a reference row; an update **does** restore it.
- An operator edits a seeded row; the preview reports it as left alone, and it
  is left alone.
- Rows exported and re-imported keep their seed key and introducing version.
