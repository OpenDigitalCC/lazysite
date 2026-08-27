---
title: "SM585: the modal editors get the manager's own frame"
subtitle: "The row and fields editors opened as modals with no frame and text to the edge - because the panels never used the house body class, and the overlay painted a second surface behind the card."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED BY THE OPERATOR 2026-08-25 on deployed 0.10.32, checking SM502 U-2/U-4 against the other manager modals as they asked. TWO CAUSES, both house style not followed: (1) .mg-card carries no padding - .mg-card-header (0.7rem 1rem) and .mg-card-body (1rem) supply it, as audit.md, edit.md and backups.md all do - and the data page's import, descriptor and row-editor panels never wrapped their content in .mg-card-body, so content sat against the card edge from the day those panels were written; the modal only made it obvious. (2) showModal painted its own background and border-radius behind the panel, stacking a second surface behind a .mg-card that already has background, border, radius and shadow. SHIPPED 0.10.33: the three panels use .mg-card-body; the overlay box only sizes and scrolls, so the card is the frame - matching the submissions modal this was modelled on. Markup balance verified by walking the div tree from each panel's opening tag to its true close rather than by eye."
---

# The house rule, restated

A manager panel is `.mg-card` + `.mg-card-header` + `.mg-card-body`. The
card supplies the frame; the body supplies the padding. Anything that
puts content directly inside `.mg-card` is missing the body, on the page
as well as in a modal.
