---
id: SM1253
title: "SM1253: the form validator reads the renderer's grammar"
subtitle: "validate_page reported rules the renderer accepts as unknown: options with spaces, quoted placeholders, file, multiple and capture. It cuts the rules as the renderer does now, and a lint derives its rule list from the renderer."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the lazysite.io site agent, inbox 2026-10-22-forms-validator-and-page-var-quotes.md (K-2)
area: validate
status-note: "SHIPPED (0.16.1) on n728: Lazysite::Validate::form_rule_tokens, a marked copy of _form_rule_tokens; %FORM_FLAGS gains file, multiple, capture; t/lint/276 pins both."
---

# What happened

`_check_form_rules` (lib/Lazysite/Validate.pm) took `select:` and the pattern
out of a field's rules and split the rest on whitespace, then reported any
plain word outside its ten-word list as `invalid-form-rule`, an ISSUE, so the
page failed. Confirmed against the renderer (`_form_rule_tokens` and
`_form_rules_from_tokens`, lazysite-processor/forms.pm), which:

- takes `radio:`, `checklist:` and `checklist-qty:` to the end of the line, as
  it does `select:` (SM401), so `radio:Yes please,No thanks` reported `thanks`;
- reads `key:"..."` as one token, so `placeholder:"Your full name"` reported
  `full`;
- accepts the bare rules `file`, `multiple` (since the upload fields) and
  `capture` (SM905), none of which was in the list.

All four findings were real.

# What shipped

- `Lazysite::Validate::form_rule_tokens` is a MARKED COPY (ADR 0001) of the
  renderer's tokeniser, without the renderer's log line. `_check_form_rules`
  checks the tokens it returns, so it sees the rules the page renders with. The
  pattern a browser gets is the `pattern:` token's value, read by the same cut
  (SM921's check is unchanged, and an escaped quote in a quoted pattern is now
  a quote, as it is in the renderer).
- `%FORM_FLAGS` gains `file`, `multiple` and `capture`.
- The policy is unchanged: only a bare lowercase word can be reported, and a
  `key:value` token is passed.

The validator cannot load the processor (ADR 0001: the render path is
module-free, and the validator runs where the processor is not loaded), so one
shared table was not possible without breaking that. The copy is held by a
lint that runs the renderer itself, so neither side can change alone.

# Left alone, for a ruling

- An unknown `key:value` (`maxx:5`, `capture:front`) is silently dropped by the
  renderer and still passed by the validator. Reporting it would be agreement
  in the other direction, but `invalid-form-rule` refuses a write, so it would
  newly refuse pages that write today.
- The validator checks the first `::: form` block of a page; the renderer
  renders every one.

# Tests

t/lint/276:

1. Every word in forms.pm, tried bare and with four values, is put to
   `_form_rules_from_tokens`; the validator passes each the renderer takes (52)
   and flags each bare word the renderer ignores. A floor of the 13 bare and 12
   valued rules guards against a renderer that takes nothing.
2. `_form_rule_tokens` and `form_rule_tokens` give the same tokens over every
   `::: form` line in starter/, docs/, website/ and t/, 17 written cases and
   2,000 seeded generated strings.
3. The reported cases pass validate_content end to end; a real typo is still
   an issue.

Sabotage: the old Validate.pm fails section 1; the new cut with the old flag
list fails section 1 and the `file` cases; the new list with a whitespace cut
fails section 2 and the option and placeholder cases.
