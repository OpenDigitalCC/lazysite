---
id: SM1298
title: "SM1298: every form's unknown-rule warning says which form, in one wording"
subtitle: "The first form's warning for a key:value the renderer ignores had no \"form 1:\" and a second wording; a later form's said \"form 2: unknown form rule ...\". Every form's now says \"form N: unknown form rule '<rule>' on field '<field>': it is not one the form reads, so it does nothing when the form renders\"."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "edge walk of 0.16.1, observation O-2"
area: forms
status-note: "SHIPPED (PENDING) on n736: Lazysite::Validate::_unknown_form_rule is the one sentence for a bare word and a key:value alike, and the first form's warnings carry \"form 1:\". t/unit/lib/206."
---

# What happened

The edge walk of 0.16.1 (O-2) saw two wordings for one finding from [[SM1264]]'s check:

- the first form, a `key:value` the renderer ignores: "form rule 'colour:red' on field
  'x' is not one the form reads, so it does nothing when the form renders" - no form
  number;
- a later form, a bare word: "form 2: unknown form rule 'requird' on field 'email'".

`_form_block_findings` worded the two kinds differently, and `_check_form_rules` added
"form N:" only to the later blocks' warnings, because the first block's findings
were pushed as they came.

# What shipped

- One sentence for a rule the form does not read, word or `key:value`:
  "unknown form rule '<rule>' on field '<field>': it is not one the form reads, so it
  does nothing when the form renders".
- Every WARNING carries its form's number, the first form's as "form 1:". What blocks
  is unchanged (ruling 11): an unknown bare word or an uncompilable pattern in the first
  form is still an issue, in the same sentence and with no number, since only the first
  form's findings can be issues.
- The finding is still said once: the first form's issue is not repeated as a warning.

# Tests

t/unit/lib/206, new block: three forms with an unknown `key:value` in each and a bare
word in the second; every warning is `form N: unknown form rule '...' on field '...':
it is not one the form reads, ...`, the first form's included, and none is worded
otherwise; the first form's issue reads the same. With the old Validate.pm all six
assertions fail.
