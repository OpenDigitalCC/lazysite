---
id: SM968
title: "SM968: A page that set TAGS let a reflected value run as a template"
subtitle: "The form prefill and outcome banner are made inert by encoding [ and %, which holds only while the tags are [% %]; a page body could switch them."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-07
raised-by: the SM869 adversarial review, second pass (WORK-PLAN-0153 Q11b)
area: security
status-note: "SHIPPED (PENDING): render_content, where every page body is parsed, turns a body's TAGS directive into a comment and logs a WARN, so the tags stay [% %] and _tt_inert's encoding holds. Layouts keep TAGS. t/unit/processor/90 fails without it."
---

# What was wrong

The form prefill (attribute and textarea) and the outcome banner write the
visitor's text into the page body BEFORE the body's template pass. `_tt_inert`
makes that text inert by encoding `[` and `%` ([[SM869]]), which is enough while
the tags are `[% %]`. A page body could change them with `[% TAGS {{ }} %]`;
after that, `?x={{ site_name }}` prefilled the site's own value - the visitor's
text was parsed as template. Preset styles whose start tag begins with `[`, `<`
or `%` were already inert; a custom pair was not, and no escape can cover every
pair an author might choose.

# The fix

render_content - the one place every page body is parsed - rewrites a body's
`[% TAGS ... %]` into a comment before parsing, and logs a WARN naming the page.
A page body uses `[% %]`; nothing shipped sets TAGS. Layouts are not affected.

# Evidence

t/unit/processor/90 (a page that sets TAGS `{{ }}`, `star` and `<+ +>`) was
committed first with the `{{ }}` case marked TODO. Without the rewrite it fails
again.

# Related

[[SM869]], [[SM965]].
