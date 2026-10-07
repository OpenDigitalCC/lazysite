---
id: SM967
title: "SM967: A value could spell one of the engine's placeholders"
subtitle: "Three passes lift text out of the page and put it back by a fixed placeholder word; a value carrying the word was restored as the block - a copy of a code span, or the page's own script moved into a form field."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the SM869 adversarial review, second pass (WORK-PLAN-0153 Q11b)
area: security
status-note: "SHIPPED (PENDING): each placeholder (RAWBLOCK in convert_md, CODEBLOCK in render_content, the NUL RAW marker in convert_p_links) carries a per-call key from one helper, _placeholder_key - random and never already in the text - so content cannot spell one. t/unit/processor/91 and t/unit/data/65 fail without it."
---

# What was wrong

convert_md lifts out script, style and comment blocks (`RAWBLOCK_n_END`),
render_content lifts out code spans before the template pass
(`CODEBLOCK_n_END`), and convert_p_links lifts out tags (`NUL RAW n NUL`). Each
restores by matching the placeholder word in the text afterwards, so a value
carrying the word was restored as the block:

- `?x=CODEBLOCK_0_END` printed by `[% query.x %]`, or a db: row with that text,
  showed a copy of the page's first code span;
- a prefilled form value `RAWBLOCK_0_END` - written into the body before the
  Markdown converter - moved the page's own `<script>` into the field. In the
  `value="..."` attribute, the script's quotes ended the attribute.

No visitor markup was introduced; author content was moved to where the visitor
chose, which changes the page's structure.

# The fix

`_placeholder_key` returns a random key that does not occur in the text being
protected, and each of the three passes puts it into its placeholder and
matches only that. A placeholder word without the key - in a value or in an
author's prose about the mechanism - is ordinary text.

# Evidence

t/unit/processor/91 (code span, prefilled converter placeholder) and
t/unit/data/65 (a row) were committed first with these marked TODO. With the key
made empty, they fail again.

# Related

[[SM869]], [[SM931]], [[SM689]], [[SM966]].
