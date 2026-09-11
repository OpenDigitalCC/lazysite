---
title: "SM843: a table has no generated key, so a form-fed table can hold only one row per person"
subtitle: "Sites agent, 2026-09-11: an insert with no key value is refused, and no field type generates one - so an enquiry table keyed on email keeps only the latest enquiry"
brand: plain
standard-margins: true
status: candidate
---

# What was measured

Probed 2026-09-10: an insert with no key value is refused - *"'ref' identifies
the row and is required"* - and the field types are text, integer, decimal,
boolean, date and enum. None generates a value.

For a table fed by a public form, the only per-submission value a visitor supplies
that can serve as a key is their email, so the table holds the **latest**
submission per person and the submissions store holds the rest. An enquiry table
usually wants one row per enquiry.

# The shape

A `uuid` or `serial` field type that the store mints on insert and that an insert
may omit. `serial` is the one a human reads; `uuid` is the one that survives a
merge of two tables. Either lands in the same place as [[SM842]], and only
matters once a form can write to a table at all.

# Related

[[SM842]].
