---
id: SM964
title: "SM964: A value that reached a page as data could become an include"
subtitle: "The second `::: include` pass ran over the template's output, so a visitor-written table row listed on a public page could pull another file into it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the SM869 adversarial review (WORK-PLAN-0153 Q11)
area: security
status-note: "SHIPPED (PENDING): render_template's second include pass is removed. It never resolved an author's template-path block (Markdown had wrapped it) and resolved blocks that arrived as data - a visitor-written row on a public page could pull an unlisted file or a sign-in-only page's body in. t/unit/data/64."
---

# What was wrong

`render_template` ran `convert_fenced_include` a second time, over the BODY AFTER
the template pass, so that a `::: include` block whose path was a template
variable could be resolved once the variable had a value.

It never did that: by then Markdown has wrapped such a block in a paragraph, so
the pattern does not match - and the docs said these blocks are not resolved.
What it did match was any block in the template's OUTPUT that arrived as data:
a value carrying line breaks could spell one. The review proved it with a row in
a public table, written through a form, listed on a public page: the row pulled
an unlisted file from the site, and the body of a page protected only by
`auth: required`, into the output. The same path was open to any stashed value
that can hold a line break (the builder's note named `request_uri` on the shipped
403 page).

# The fix

The second pass is removed. A block whose path holds a template variable is left
as written, as the docs already said; that is now the design rather than a gap,
because a path taken from data hands the choice of file to whoever writes the
data. Includes the author writes with a literal path are unchanged.

# Evidence

t/unit/data/64: a row carrying an include block does not pull a file in (fails
on n269's processor); an author's literal include still resolves; a path from a
template variable is not resolved. The processor, data and integration suites
pass.

# Related

[[SM869]] (whose review found it), [[SM857]].
