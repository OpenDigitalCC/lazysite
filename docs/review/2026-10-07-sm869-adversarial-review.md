---
title: "SM869 adversarial review - 2026-10-07"
subtitle: "Query values to rendered output, and the render path around them. One hole proved and fixed (SM964); the review stopped early, so several attack classes are still owed."
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

The review agent stopped before finishing, and its report was cut short. These
classes from the brief were NOT tried and remain owed (WORK-PLAN-0153 Q11b):

- encoding variants (multiple URL-encoding, entity forms of `[` and `%`, CR
  alone, U+2028/2029, NUL, invalid UTF-8);
- Markdown-converter interplay (code spans, autolinks, reference links turning
  escaped text back into markup);
- attribute contexts in shipped layouts and starter pages (unquoted attributes);
- template syntax split across two parameters, and the `TAGS` directive;
- `api:` pages' JSON context (the builder notes values are HTML-escaped, not
  JSON-escaped).

# Outcome

SM869's build stands; SM964 and SM965 are fixed on n270. A second review pass over the
classes above is queued.
