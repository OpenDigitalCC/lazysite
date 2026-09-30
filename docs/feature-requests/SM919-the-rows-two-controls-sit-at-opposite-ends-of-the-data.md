---
id: SM919
title: "SM919: a row's tick box and its Delete button sit at opposite ends of the data"
subtitle: "Reported from the live manager while managing form submissions. A submissions table has one column per form field, so it scrolls horizontally - and the tick box is the FIRST cell while Delete is the LAST, with every data column between them. At any scroll position an operator can reach one or the other, so selecting a row and then deleting it means crossing the whole table and coming back. The modal made it worse by capping itself at 1000px on a screen with more to give, creating some of the scrolling it was then hard to use."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-30 on claude/sm919-the-rows-controls-stay-with-the-row. PINNED, NOT MOVED OUT: the tick box sticks to the left edge and the actions cell to the right, with the data scrolling between them, so both are reachable at every scroll position without eye travel. The cells stay IN the row, which is the safety argument - an actions strip rendered beside the table has to keep its own row heights in step with the data's, and a drift of one row aims Delete at the wrong submission; pinning leaves the browser's own row association intact. Pure CSS (position: sticky), identical in all three manager themes and added by one script so they cannot drift. Hover is deliberately not restated: the existing `.mg-table tbody tr:hover td` out-specifies these selectors and still wins, so a pinned cell highlights with its row. THE WINDOW is 90vw by 90vh FIXED, replacing width:92%/max-width:1000px/max-height:86vh - the cap wasted a wide screen and created scrolling that need not have existed, and max-height with no height meant every form opened at a different size so the scroll region moved between visits. AND THE STYLE GUIDE NOW SHOWS IT: its mg-submissions-table demo was a single cell, so the one state that matters - wide enough to scroll, with pinned ends - could not be seen on the page whose whole purpose is to show what a diff cannot. It has eight columns and two rows of test content now, one of them quarantined, so the pinning is visible by scrolling the demo."
raised: 2026-09-30
raised-by: release manager, from the live manager
area: manager
---

# What was reported

Managing form submissions: the delete button and the tick box are inside the
table rows, so once scrollbars appear one is at one end and the other at the
other. The actions performed on a data row should be outside the data's
scrollbars. And since the data is likely to be large, a big window of a fixed
size - say 90% - would be more manageable once scrollbars appear.

# What the markup was doing

Confirmed in `starter/manager/plugin-config.md` before changing anything. The
viewer builds each row as:

    cbCell  -> a tick box                      (cell 0)
    st      -> the quarantine status
    cols    -> ONE CELL PER FORM FIELD         (however many the form has)
    act     -> Confirm / Delete                (last cell)

So the two controls an operator uses together are separated by the whole of the
variable-width part of the table, inside `div.mg-table-wrap`, which is
`overflow-x: auto`. A contact form with eight fields overflows a laptop display,
and the round trip is per row.

# Pinned, rather than moved out of the table

"Outside the data scrollbars" has two readings, and the difference matters
because one of these controls deletes a submission permanently.

Rendering the actions in their own element beside the scroll area is the literal
reading. It also requires the strip's row heights to track the data's, and
submission cells wrap - a long enquiry is three lines, a short one is one. Row
heights therefore vary with content, and any drift between the two columns aims
Delete at a row the operator was not looking at. That failure is silent and
destructive, which is the worst pair.

Pinning the cells with `position: sticky` gives the operator the same thing -
neither control scrolls away - while leaving the association structural. The
button is in the row it acts on because the browser put it there, not because two
elements agreed about heights.

```datatable
columns: Cell | Behaviour
widths: 6cm | X
bold: 1
tone: medium
---
tick box (first) | pinned to the left edge, data scrolls to its right
the form's fields | scroll, as before
Confirm / Delete (last) | pinned to the right edge
```

Two details that are decisions rather than defaults. The pinned cells carry an
opaque background, because the data scrolls UNDERNEATH them and a transparent
cell shows two values at once. And hover is NOT restated in the new rules: the
existing `.mg-table tbody tr:hover td` is the more specific selector and still
wins, so a pinned cell highlights with its row and the row still reads as one
thing.

# The window

`width: 92%; max-width: 1000px; max-height: 86vh` became
`width: 90vw; height: 90vh`.

The cap was doing real harm rather than nothing: on a wide display the table
scrolled horizontally with half the screen unused beside it, so some of the
scrolling the report is about was created by the dialog rather than by the data.
And `max-height` without `height` sizes the box to its contents, so every form
opened at a different size and the scroll region moved between visits - a control
an operator cannot build a habit around.

# The style guide could not have shown this

Its `mg-submissions-table` entry was a table with one cell in it. The class was
registered, so t/lint/96 passed, and the state that matters - wide enough to
scroll, with a pinned first and last cell - was not on the page whose entire
purpose is to show what a diff cannot.

That is the same gap in miniature that the lint's own header describes: three
defects that were correct in source and wrong in the browser. A registered class
with no representative state is a half-kept contract. The demo now has eight
columns, two rows, and a quarantined one, so scrolling it sideways demonstrates
the behaviour this filing is about.

# Not done

No test asserts the pinning, and a lint cannot: `position: sticky` is a rendering
behaviour, and the classes and rules it needs are already checked in both
directions by t/lint/96. What would catch a regression is a walk of the style
guide's own demo, which is why the demo was made representative rather than a
test written against the CSS text.
