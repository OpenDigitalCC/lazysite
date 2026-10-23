---
id: SM1252
title: "SM1252: a stepped form is not paragraph-wrapped"
subtitle: "A multi-step form's output began with its stylesheet <link>, which the Markdown pass does not take for block HTML, so it wrapped the head of the form in <p>. The link is inside the form now."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the lazysite.io site agent, inbox 2026-10-22-forms-validator-and-page-var-quotes.md (K-1)
area: forms
status-note: "SHIPPED (0.16.1) on n728: _render_form emits the step <link> after the opening <form> tag; t/unit/processor/149; t/unit/processor/112's record re-recorded for the two stepped cases."
---

# What happened

`_render_form` returned `$banner$step_css<form ...>`, so a stepped form began
with `<link rel="stylesheet" href="/assets/lazysite-chrome.css">`. Reproduced
from the code, under a layout and without one: the page came out as
`<p><link ...><form ...>` and the hidden inputs `</p>`, then `<p></form>`. A
single-step form, which begins with `<form`, came out clean.

# Why not the suggested fix

The report put it down to `unwrap_block_html` (lazysite-processor/include.pm)
not listing `link`. True, but adding it was tried and is not enough: it strips
only the `<p>` before the link. The `</p>` after the hidden inputs and the
`<p>` before `</form>` are left, because the Markdown pass had already made a
paragraph of everything up to the first block element inside the form. It is
the Markdown pass's reading of the block that is wrong, not the clean-up after
it.

# What shipped

The step stylesheet's `<link>` is emitted on its own line just after the opening
`<form ...>` tag. The form's output starts with `<form`, as a single-step form's
does, and passes through the Markdown pass as block HTML. A stylesheet link is
valid in the body, and the step rules apply as before. `unwrap_block_html` is
unchanged.

# Tests

t/unit/processor/149 renders a stepped and a single-step form end to end, with
no layout and under one: no `<p>` or `</p>` between `<form` and `</form>`, none
wrapping the start, and the following text still its own paragraph. With the
old forms.pm, the four stepped-form assertions fail and the single-step control
passes. t/unit/processor/112's record changes in exactly the two stepped cases,
where the link moves inside the form.
