---
id: SM1264
title: "SM1264: a form rule the renderer ignores is a warning"
subtitle: "validate_page passed any key:value rule and read only the first form block of a page. It reports both now, as warnings that never block a save; what blocked before is all that still does."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: SM1253's "left alone, for a ruling"; ruled by the release manager 2026-10-22
area: validate
status-note: "SHIPPED (0.16.1) on n728: unknown-form-rule and pattern-will-not-compile warnings in Lazysite::Validate; t/unit/lib/206, t/unit/mcp/01, t/lint/276."
---

# What happened

After SM1253, `_check_form_rules` agreed with the renderer about bare words but
still had two gaps, both recorded there for a ruling:

- Any `key:value` token was passed. The renderer sets nothing from one it does
  not read (`maxx:5`, `capture:front`, `max:many`), so a typo in a key went
  unreported and the field quietly lost the rule.
- Only the first `::: form` block of a page was read, by a looser match than
  the renderer's; `convert_fenced_form` renders every block.

# The ruling (2026-10-22)

Report both, as WARNINGS that never block a save. `invalid-form-rule` keeps
blocking only what it blocks today.

# What shipped

- `form_value_rule_known`: the valued branches of `_form_rules_from_tokens`
  (accept, capture:user|environment, select, radio, checklist, checklist-qty,
  max:N, min:N, pattern, placeholder, value, prefill), a marked copy beside
  `form_rule_tokens`.
- The first block, found by the same match as before: an unknown bare word is
  still the issue `invalid-form-rule` and a pattern a browser cannot compile
  still `uncompilable-pattern`; an unknown key:value there is the warning
  `unknown-form-rule`.
- Every block, fenced as the renderer fences them: anything not already
  reported is a warning, prefixed with the block's number (`form 2: ...`) -
  `unknown-form-rule` for a word or key, `pattern-will-not-compile` for a
  pattern.
- `valid` is unchanged in meaning (false iff an issue), so a page carrying
  only these warnings validates and saves everywhere it did.

# Tests

- t/unit/lib/206: four unknown key:values each give a warning and no issue,
  and the page stays valid; six valued rules the form reads give none; the
  first block's word and pattern are still issues, and not repeated as
  warnings; a typo in a second form and a broken pattern in a third are
  warnings naming their form; `lazysite validate` passes the page and prints
  the warning; a manager `save` of it succeeds and writes the page.
- t/unit/mcp/01: through MCP, validate_page answers valid with both warnings,
  and write_file saves the page.
- t/lint/276: `form_value_rule_known` agrees with `_form_rules_from_tokens` on
  every word in forms.pm with nine shapes of value.
- t/lint/139: the two warning kinds are listed as deliberate.

With the SM1253 Validate.pm restored, every warning assertion in 206 and 01
fails, and 276 cannot call the reader; the saves and the issue assertions pass
either way, which is the ruling's other half.
