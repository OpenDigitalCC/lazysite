---
id: SM1104
title: "SM1104: an info mark's note shows on keyboard focus"
subtitle: "The note is drawn from data-note on hover and :focus-visible in all three manager stylesheets, so a keyboard user reads it too."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: 0.15.6/0.15.7 test plan, row N4
area: manager
status-note: "SHIPPED on n613: manager-classic/-modern/-accessible.css .mg-info[data-note]; plugin-config.md, plugins.md, data.md; t/unit/manager/348 (real browser)."
---

# What happened

Row N4 of the 0.15.6/0.15.7 results:

    47 info marks over 11 extension forms, each with its note in title and
    aria-label and tabindex 0 ... FAIL on 'tabbing shows the text': :focus
    only recolours the mark (manager-*.css 1263/1383), so a sighted keyboard
    user never sees the note - it shows on mouse hover (native title) and to
    screen readers only.

# What shipped

The mark carries its escaped note in `data-note` (and still in `aria-label`);
the `title` is gone, since the native tooltip would repeat the drawn one. Each
manager stylesheet draws `attr(data-note)` as a `::after` box on `:hover` and
`:focus-visible`: below the mark, wrapping at 22rem, in the theme tokens, with
an empty alt so a screen reader does not read it twice. A mark in the
Extensions row's right-hand column opens leftwards so it does not clip. No
JavaScript. The Escape key does not dismiss it; moving focus or the pointer
does.
