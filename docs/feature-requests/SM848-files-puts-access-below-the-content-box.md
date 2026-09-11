---
title: "SM848: on Files, 'Access - owner, and who may read or write this file' sits below the content box"
subtitle: "Release manager, 2026-09-11, on 0.13.12: it should sit above it"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11. The Access section (owner, and who may read or write this file) is in the editor Files opens, and it now sits after the front-matter fields and above Metadata and Content, rather than after the content box. Above Metadata rather than just above Content, so the splitter between those two still resizes exactly them. It still loads on first open. Pinned by section order in the editor pane's markup, not by a screenshot."
---

# As reported

In the Files app, the section *"Access - owner, and who may read or write this
file"* should sit **above** the content box.

Recorded as reported and not yet re-measured.

# Why the order is not cosmetic

Who may read a file is a fact an operator wants before they edit it, not after.
A protected file's access state placed under a long content box is the SM635 shape
- the one row that most needs to say "held back" being the one a person scrolls
past.

# Related

SM635 (a protected folder that read as open).
