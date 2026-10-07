---
id: SM965
title: "SM965: A reflected form value could become an include"
subtitle: "A form's prefill and outcome banner reach the body before the first include pass, and their line breaks were kept - so a crafted link could spell a `::: include` block."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the SM869 adversarial review (WORK-PLAN-0153 Q11)
area: security
status-note: "SHIPPED (PENDING): _tt_inert, the one helper every pre-template-body sink uses (prefill attribute, prefill textarea, outcome banner), now encodes CR/LF as well as [ and %, so a reflected value cannot spell a block for the FIRST include pass. t/unit/processor/89; both B and C fail without it."
---

# What was wrong

SM869 made the form prefill (attribute and textarea) and the outcome banner
escape HTML and neutralise template syntax (`_tt_inert`). They are written into
the body BEFORE the first `::: include` pass (convert_fenced_form runs before
convert_fenced_include), and that pass reads a newline-delimited block as a
directive. `_tt_inert` left line breaks alone, so a value carrying lines of its
own - delivered in a link a visitor is sent - pulled a file from the content
root into the page. Reflected, not stored; the include reach excludes `lazysite/`
and `..` traversal (t/unit/processor/89 asserts both).

# The fix

`_tt_inert` also encodes CR and LF as `&#13;`/`&#10;`, which a browser shows as
the line breaks typed, so a genuine multi-line value still displays. It is the
one helper all three sinks call, so a fourth cannot reopen it.

# Evidence

t/unit/processor/89 (committed first with the two holes as TODO): prefill (B) and
banner (C) cannot name a file; a genuine multi-line value keeps both lines. With
the CR/LF lines removed, B and C fail.

# Related

[[SM869]], [[SM964]].
