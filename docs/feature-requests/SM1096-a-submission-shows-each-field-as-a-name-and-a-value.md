---
id: SM1096
title: "SM1096: a submission shows each field as a name and a value"
subtitle: "The submission view puts a field's name above its value as a label, and keeps a multi-line value's newlines."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.5 test plan, T7)
area: manager
status-note: "SHIPPED on n606: starter/manager/submission.md render(), the three manager stylesheets; t/unit/manager/343."
---

# What happened

The owner's observation from the manager in the 0.15.5 test plan:

    The submission view runs a field's name and value together
    ("messagezz55 F9 event 2"), so the body does not read as a body.

`render()` on /manager/submission put a field's name and its value in two bare
`<span>`s, which sit side by side with nothing between them. A value's newlines
collapsed to spaces as well, because nothing told the browser to keep them.

# What shipped

Each field is its own block: the name as a small label (`.mg-field-name`), the
value below it (`.mg-field-value`). The value is still set as text, so markup in
a submission is shown and never parsed. The stylesheets give the value
`white-space: pre-wrap`, so a body keeps its newlines (SM928), and wrap a long
unbroken run inside the card.

t/unit/manager/343 drives the page's own `render()` in node: a name node and a
value node apart, the value's newlines intact, markup kept as text, no
`innerHTML`, and the pre-wrap rule present in all three manager styles.
