---
id: SM751
title: "SM751: SM742's NOT NULL translation is unreachable through every supported insert path, and the code now says so"
subtitle: "The 0.13.0 field pass reached UNIQUE easily and reported that NOT NULL could not be reached - 'not proved' rather than a borrowed sentence offered as evidence. They were right, and the answer is stronger than either side could see from the surface."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.13.1 (landed 2026-09-05, commit aa92df6d, under the label SM751 - this document was written at the pre-cut pass). The NOT NULL branch of Tables::_constraint_error is kept as a safety net and its comment says it is unreachable; t/unit/data/53 pins the two guards that make it so."
---

# What the field said

The site agent testing 0.13.0's SM742 (a constraint failure reads as prose)
reached the UNIQUE case at once and reported that NOT NULL could not be
constructed from the descriptor surface: a field marked `required` is refused by
`Value.pm` before any SQL runs, so the database never gets the chance to object.
They said "not proved" and did not offer the value layer's sentence as evidence
for the translator - which is [[feedback_gate_evidence_needs_weaker_grant]]'s
rule applied correctly by somebody else.

# What is true

`SQLite.pm` emits `NOT NULL` for exactly two things: a `required` field, and a
non-auto key. `Value.pm` refuses both before any SQL - the first at its
required check, the second at a dedicated key check whose sentence is better
than the translator's, because it says why the key is needed rather than only
that it is missing. The two conditions are the same two. **Nothing that would
violate the constraint reaches the database.**

The gap that looked real - a key not named `id` carries NOT NULL without being
`required`, a common shape (the agent's own probe table was keyed on `code`) -
is already guarded. The test written to expose the branch exposed the guard.

# What shipped

- `t/unit/data/53` pins the behaviour that happens: both NOT-NULL-emitting
  conditions are refused at the value layer with their own sentences.
- `t/unit/data/52` no longer claims NOT NULL is exercised.
- The translator's NOT NULL branch stays, commented as unreachable through the
  supported paths and kept as a safety net for an unsupported one.

# Related

SM742 (the translation), SM732 (record what a test does not prove).
