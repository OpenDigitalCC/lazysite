---
id: SM985
title: "SM985: a code fence showing `:::` syntax was expanded"
subtitle: "A ``` block that shows how a component is written rendered the component, escaped, inside its own code block."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, a style guide on a local 0.15.3 site); WORK-PLAN-0154 P6
area: rendering
status-note: "SHIPPED (0.15.5): fenced code blocks are converted first and held out of the ::: passes (form, components, divs, include, oembed), then put back; a code block inside a box is still a code block (t/unit/processor/96)."
---

# What was wrong

The `:::` passes - `convert_fenced_form`, `convert_fenced_components`,
`convert_fenced_divs`, `convert_fenced_include` and `convert_oembed` - run on
the page body before `convert_fenced_code` (lazysite-processor/pipeline.pm,
`process_md` and `process_url`; the Markdown include in
lazysite-processor/include.pm). Each matches `:::` at the start of a line,
which is where a ``` block showing the syntax puts it. So the example was
rendered as the component, and the code block then showed the component's
markup, escaped. An include example was included; a form example rendered
a form.

An indented code block was never affected: its lines do not start with `:::`.

# The fix

`lift_fenced_code` (include.pm) converts each fenced block to its
`<pre><code>` first, as `convert_fenced_code` would (`_fenced_code_html`,
now shared), and holds it out by a placeholder keyed per call (SM967), so no
`:::` pass sees it. After the `:::` passes and oembed, the closure it returns
puts each block back, dropping a paragraph a box's own Markdown pass wrapped
around the placeholder. Every body that runs the `:::` passes does this: the
normal and raw page paths, a `.url` page and a Markdown include.

# Tests

t/unit/processor/96: a component, box, include and form example in a fence
are shown as written and not made; live fences outside code still work; a
code block inside a box or a component is still a code block, escaped, with
no paragraph around it and no placeholder left.
