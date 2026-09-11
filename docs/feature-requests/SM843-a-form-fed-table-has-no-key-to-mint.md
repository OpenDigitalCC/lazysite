---
title: "SM843: a table has no generated key, so a form-fed table can hold only one row per person"
subtitle: "Sites agent, 2026-09-11: an insert with no key value is refused, and no field type generates one - so an enquiry table keyed on email keeps only the latest enquiry"
brand: plain
standard-margins: true
status: superseded
status-note: "ALREADY ANSWERED, verified 2026-09-11 and not built. The generated key the filing asks for exists: a table that declares no key (or key: id) numbers its own rows as an integer id, which an insert omits and no field may shadow (Lazysite::Data::Descriptor _check_key). The table measured was keyed on a field, ref, so an insert had to carry it. A form-fed table that wants one row per enquiry leaves key: out; t/integration/76 now feeds such a table twice from the same email and gets two rows with distinct ids. What was missing was the sentence: /docs/data-tables has a section, 'A table that numbers its own rows'. A uuid type, the filing's second shape, is not asked for by anything that exists."
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
