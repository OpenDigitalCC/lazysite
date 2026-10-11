---
id: SM984
title: "SM984: a template tag in a page body was converted as Markdown"
subtitle: "`[% IF a && b %]` reached Template Toolkit as `[% IF a &amp;&amp; b %]`, a parse error, and the page showed its own source."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, a 1,745-post site on 0.15.3, item 3); WORK-PLAN-0154 P5
area: rendering
status-note: "SHIPPED (PENDING): convert_md lifts each [% %] tag out before the Markdown converter and puts it back as written; a tag in code is put back escaped and is not run; the markdown filter is unchanged (t/unit/processor/95)."
---

# What was wrong

A page body is converted from Markdown before the template pass
(lazysite-processor/pipeline.pm, `convert_md` then `render_template`), so the
author's `[% ... %]` tags went through Text::MultiMarkdown as prose
(lazysite-processor/include.pm, `convert_md`). The converter escapes `&` and a
bare `<` in prose, so `[% IF a && b %]` reached TT as
`[% IF a &amp;&amp; b %]`: "template error, using raw content ... unexpected
token (&)", and the page showed its source. `and`, `or` and `not` worked.
`[% IF n < 5 %]` failed the same way, and two tags each holding `*` could be
paired into `<em>` across the text between them.

# The fix

`convert_md` lifts each `[% ... %]` out of the body before the converter, by a
placeholder the content cannot spell (SM967's key), and puts it back as
written afterwards. Text outside the tags is converted and escaped exactly as
before.

Code stays code: a `<pre>` block already converted by `convert_fenced_code`
(which escaped it) is passed over, and a tag the converter places inside a code
span or an indented block is put back escaped, as the converter would have
left it, so it is shown and not run.

A visitor cannot spell a tag in the body: the form prefill and outcome banner,
written in before this pass, have `[` and `%` encoded (`_tt_inert`). The
`markdown` TT filter converts a value rather than the author's body, passes
`tt => 0`, and is unchanged. The SM964-SM969 inert-value tests
(t/unit/processor/88-92, t/unit/data/64-65) pass unchanged.

# Tests

t/unit/processor/95: `&&`, `||`, `<` and two `*` tags run, in prose and in an
HTML block; prose `&` and `<` are still escaped; a tag in a code span, an
indented block and a fenced block is shown escaped.
