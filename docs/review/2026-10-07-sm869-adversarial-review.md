---
title: "SM869 adversarial review - 2026-10-07"
subtitle: "Query values to rendered output, and the render path around them. The first pass proved and fixed SM964 and SM965 and stopped early; the second pass (n271) covered the classes it owed and fixed SM966-SM969."
brand: plain
standard-margins: true
---

# Scope

The build on n269 (SM869) moved query-value escaping to one point - the template
stash - and made the form prefill, textarea and outcome banner escape and
neutralise template syntax themselves. The builder's own hostile-value test
(t/unit/processor/88) covers eight value shapes through every path it found.
This review was asked to break that and the render path around it, in local
fixtures only.

# What was proved

**Stored include through the second include pass (SM964, fixed).** The builder
flagged it as a reading; the review reproduced it. `render_template` resolved
`::: include` blocks in the template's output, so a table row carrying one,
written by a visitor through a form and listed on a public page, pulled an
unlisted file and a sign-in-only page's body into the output. Fixed at the root
by removing the second pass (it had never resolved an author's block);
t/unit/data/64.

**Reflected include through the form prefill and banner (SM965, fixed).** The
same block shape, through the values SM869 writes into the body before the FIRST
include pass; `_tt_inert` kept their line breaks. Fixed in that one helper;
t/unit/processor/89, which also shows the include reach stops at the content
root.

# What was not covered

The first pass stopped before finishing. The five classes it owed - encoding
variants, Markdown-converter interplay, attribute contexts, split template
syntax with the `TAGS` directive, and the `api:` JSON context - were taken by
the second pass below (WORK-PLAN-0153 Q11b). None remains owed.

# Second pass (n271)

Ordinary tests driving the real processor on local fixtures:
t/unit/processor/90 and 91, t/unit/data/65, t/lint/212. Each was committed first
with what failed marked TODO; each fix was confirmed by reverting it.

**Encoding variants - covered; one defect fixed (SM966).** Double
percent-encoding, entity forms of `<`, `[` and `%`, a lone CR, U+2028/2029 and
invalid UTF-8 held at every sink (page body, attribute, layout, raw page, api
page, prefill attribute and textarea, outcome banner): no element, no
evaluation, a 200. NUL did not: it broke the api page's JSON, and a value
spelling convert_p_links' NUL placeholder pulled the layout's `<script>` into
the text. Fixed with the rest of SM966.

**Markdown-converter interplay - covered; two defects fixed (SM966, SM967).** A
value beside a code span, beside an autolink, or as a reference-link label
stayed text. Inline link syntax did not: convert_p_links reads the rendered
text, so a query value or a db: row spelling `[text](url)` became an anchor.
SM966 encodes brackets in every data value. And a value spelling an engine
placeholder (`CODEBLOCK_n_END`, `RAWBLOCK_n_END`) was restored as the block - a
copy of a code span, or the page's script moved into a prefilled field; SM967
gives each placeholder a per-call key.

**Attribute contexts - covered; nothing to fix.** The shipped starter pages,
layouts, templates and the processor's built-in layout place no template value
in an unquoted attribute; t/lint/212 holds it. A value with a space or `>` stays
inside a quoted attribute at every sink.

**Split template syntax and TAGS - covered; one defect fixed (SM968).** Template
syntax split across two parameters is never evaluated - the stash is read once
and the pre-template sinks encode `[` and `%`. A page body that set
`[% TAGS {{ }} %]` let a prefill or banner value evaluate; a body's TAGS is now a
comment.

**`api:` JSON context - covered; fixed with SM966.** A trailing backslash, a tab,
a control character or NUL in a query value or a db: row made the response
invalid JSON. They are character references in a data value now, so the JSON
always parses.

**Found on the way (SM969, fixed).** The form outcome banner was written to the
page cache on a cold-cache request, so one visitor's link text was shown to
every later visitor.

Left open, as outside these classes: a value an author places as the WHOLE of
a link target (`href="[% query.x %]"`) is escaped but its scheme is not checked;
that is the author's choice of sink.

# Outcome

SM869's build stands. SM964 and SM965 are fixed on n270; SM966, SM967, SM968 and
SM969 on n271. The classes the first pass owed are covered.
