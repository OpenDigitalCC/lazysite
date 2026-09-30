---
id: SM923
title: "SM923: two limits a long native form runs into"
subtitle: "From building a 31-field business diagnostic on a live site. The form grammar has no section construct, so a long form is one undifferentiated run of fields; and a table handler's field map is required and capped at 500 characters, so a form of this size cannot reach a data table without mangling its column names. The reporter is explicit that neither is a defect - both changed the design of the thing being built, which is what makes them worth recording."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-29
raised-by: site agent, from a 31-field form on a live site
area: forms
---

# Why this is filed at all

Neither limit is a fault: the grammar does what it documents and the cap is a
declared cap. They are filed because a long form is a shape the grammar has not
met before, and both limits changed what got built rather than merely annoying
somebody. That is the difference between a wish and a report.

# 1. No section construct

A 31-field form renders as one run of fields. There is no way to say "these six
belong together under this heading", so the page gives a reader no structure to
navigate and no sense of how much is left.

What a form of this length needs is not obvious from what a short one needs, so
this wants a decision about shape rather than a feature request granted as
described. At least three shapes exist: a `section:` rule in the field list, a
fieldset emitted from a heading in the surrounding Markdown, or multiple `:::form`
blocks posting to one handler.

# 2. The table handler's field map is required, and capped at 500 characters

To land in a data table, a form needs a field map, and the map is required and
limited to 500 characters. At 31 fields that budget is roughly sixteen characters
per pair, so the names have to be abbreviated to fit - which means the column
names in the table stop matching the field names on the form, and the person
reading the table later has to keep the mapping in their head.

The cap presumably exists to bound a conf value. The interesting question is
whether the map needs to be required at all: if a field name is already a legal
column name, the identity mapping is derivable, and the map could carry only the
exceptions. That would make a long form's map short and a short form's map empty.

# What wants deciding

  - whether a section construct is wanted, and in which of the three shapes;
  - whether the field map should default to identity, so it carries only
    exceptions - and if so, whether the 500-character cap then still binds
    anything worth binding.

Both are shape decisions that precede any build, which is why nothing is proposed
here as ready.

# Related

[[SM857]] (the handler's row policy, the most recent work on this path),
[[SM905]] (the grammar's most recent additions), [[SM888]] (A5).
