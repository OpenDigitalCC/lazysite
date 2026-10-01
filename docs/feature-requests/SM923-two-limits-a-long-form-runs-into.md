---
id: SM923
title: "SM923: two limits a long native form runs into"
subtitle: "From building a 31-field business diagnostic on a live site. The form grammar has no section construct, so a long form is one undifferentiated run of fields; and a table handler's field map is required and capped at 500 characters, so a form of this size cannot reach a data table without mangling its column names. The reporter is explicit that neither is a defect - both changed the design of the thing being built, which is what makes them worth recording."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-29
raised-by: site agent, from a 31-field form on a live site
area: forms
status-note: "PARTIAL (80cec083) 2026-10-01: LIMIT 2 IS BUILT, LIMIT 1 IS STILL FILED. THE 2026-09-30 RULING WAS AMENDED ON MEASUREMENT BEFORE ANYTHING WAS WRITTEN. It said the field map DEFAULTS TO IDENTITY, which makes it optional. Measuring what reaches a handler showed why it cannot: `_visible_fields` (form-handler.pl:1270) strips only `_`-prefixed keys, so EVERY other key a visitor posts arrives at the handler, including keys the form never declared - and the map is what drops them. With `name=full_name, message=body`, a visitor who also posts `status=approved` writes nothing extra; under an identity default the same submission writes `status`, and the bound table's own column set becomes the only limit (tmp/measure-identity-map-exposure.pl). The schema note for `fields` says in those words that the map is "what keeps a visitor from choosing where their data goes", and that is literally true. RE-ASKED AND RULED 2026-10-01: RAISE THE CAP, KEEP THE MAP. The 500-character bound is now PER FIELD (`max_len` in the schema, default 500) and the map's is 4000, which carries any realistic form - the 31-field one that produced the report needs about 1,000 - while still bounding the conf value, which is what the cap was for. That removes the harm the reporter actually measured: column names no longer have to be abbreviated until they stop matching the field names on the form. The refusal names the limit it applied, which it did not before: it said 500 while a different number was in force. WHAT THE AMENDED RULING DOES NOT DELIVER, said plainly: a short form's map is not EMPTY, because the map is still required. That was the second half of the original ruling's appeal and it is the half that cannot be had without making the map optional. LIMIT 1, THE SECTION CONSTRUCT, IS NOT BUILT and the original reasoning stands unchanged: a grammar rule is documented, tested and supported forever, and none of the three candidate shapes should be chosen on a single report. It waits for a second long form to ask. Four sabotages, four refusals. Original ruling follows. RULED 2026-09-30, AND SPLIT. Limit 2 IS ACCEPTED: the table handler's field map DEFAULTS TO IDENTITY, so it carries only the exceptions - a field name that is already a legal column name needs no entry, which makes a long form's map short and a short form's map EMPTY. The 500-character cap then stops binding anything worth binding and can stay as the conf bound it was presumably there to be. That removes the actual harm the reporter measured: at 31 fields the map allowed roughly sixteen characters per pair, so column names had to be abbreviated until they no longer matched the field names on the form. Limit 1, the SECTION CONSTRUCT, IS NOT BUILT and stays filed: a 31-field form is one form, and none of the three candidate shapes (a `section:` rule in the field list, fieldsets emitted from surrounding Markdown headings, multiple `:::form` blocks posting to one handler) should be chosen on a single report - a grammar rule is documented, tested and supported forever. It waits for a second long form to ask, at which point the two reports together will say which shape is actually wanted. NOT A DEFECT EITHER WAY, which is why neither half is urgent: the grammar does what it documents and the cap is declared. BUILD NOTE for limit 2: 'already a legal column name' is the whole contract and it must be ONE predicate shared with whatever validates a column name today, not a second opinion about what is legal - and a form whose field name is NOT legal must still be refused with the name in the message rather than silently identity-mapped to something the table rejects."
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

# What wanted deciding, and what was decided

  - whether a section construct is wanted, and in which of the three shapes;
  - whether the field map should default to identity, so it carries only
    exceptions - and if so, whether the 500-character cap then still binds
    anything worth binding.

Both were shape decisions that precede any build, which is why nothing was proposed
here as ready.

## Ruled 2026-09-30: the field map, and not the sections

**Limit 2 is accepted: the field map defaults to identity.** A field name that is
already a legal column name needs no entry, so the map carries only exceptions -
a long form's map becomes short and a short form's map becomes empty. The
500-character cap then stops binding anything worth binding and can stay as the
conf bound it presumably was.

That is the half where the harm was actually measured: at 31 fields the budget
allowed about sixteen characters per pair, so column names were abbreviated until
they stopped matching the field names on the form, and the person reading the table
later had to hold the mapping in their head.

**Limit 1 is not built and stays filed.** A grammar rule is documented, tested and
supported forever, and none of the three shapes should be chosen on one report.
It waits for a second long form to ask - two reports will say which shape is wanted
in a way one cannot.

**The build has one trap worth naming.** "Already a legal column name" is the whole
contract, so it must be the SAME predicate that validates a column name today, not
a second opinion about what is legal. And a field whose name is not legal must be
refused with the name in the message - not silently identity-mapped into something
the table then rejects, which would move a clear error to a later and stranger one.

# Related

[[SM857]] (the handler's row policy, the most recent work on this path),
[[SM905]] (the grammar's most recent additions), [[SM888]] (A5).
