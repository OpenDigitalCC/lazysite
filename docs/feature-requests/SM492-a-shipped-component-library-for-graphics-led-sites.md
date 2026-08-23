---
title: "SM492: the component mechanism exists and almost nobody can reach it"
subtitle: "Markdown is not the problem and the component system is not missing. It ships one component, documented nowhere, that cannot be moved between sites - so the fast path for a visual page is still hand-authored HTML. Six proposals, in order"
brand: plain
standard-margins: true
status: candidate
status-note: "FROM THE FIELD 2026-08-22, filed 2026-08-23. An estate survey of the graphics-led sites (DHCF, mm-gallery, the Studio) found the same hero panel built twice by hand because nothing told either author a component existed. The engine already does more than it is given credit for - sections:, ::: component fences, json: data loops - and none of it reaches the visual sites because it is undocumented and unportable. SIX PROPOSALS, AND THE REPORTER'S ORDER IS THE RIGHT ONE: GS9 and GS12 first, both writing not code - document sections: and ::: component in ai-briefing-layouts with one worked example, and put json: in the briefings with a gallery worked end to end; either would have changed how DHCF and mm-gallery were built. Then GS7 + GS8 together - a standard component set (hero, band, stats, cards, gallery, media, quote, cta, logos, video) in the any-layout directory, each with its own CSS written against theme tokens and mirrored with the theme - since neither is much use alone. Then GS10 (components-list on the control API) and GS11 (warn on an unmatched component fence in validate_page and the build), both small, both what make the rest safe to use. NOT A DEFECT, AN ABSENCE, and the absence is costing real sites real hand-written HTML today. SIZE: GS9+GS12 S each; GS7+GS8 L together; GS10, GS11 S each. The survey and its evidence are in inbox/archive/2026-08-22-graphics-led-sites-the-mechanism-exists-and-nobody-can-reach-it.md."
---

# The finding

The same hero panel, built twice, by hand, on two sites -- because nothing told
either author that `::: component` existed. The engine ships the mechanism and
one component, documents neither, and cannot move a component between sites.
So the fast path for a visual page remains hand-authored HTML, which is the
thing the guard rails exist to discourage.

# Six proposals, in the order to do them

```datatable
columns: Ref | Proposal | Size
widths: 1.6cm | X | 1.6cm
bold: 1
tone: medium
---
GS9 | Document `sections:` and `::: component`, with one worked example | S
GS12 | Put `json:` in the briefings, with a gallery worked end to end | S
GS7 | Ship a standard component set in the any-layout directory | L (with GS8)
GS8 | Give each shipped component its own CSS, against theme tokens, mirrored with the theme | L (with GS7)
GS10 | `components-list` on the control API: name, attributes, slots, origin | S
GS11 | Warn on an unmatched component fence in `validate_page` and the build | S
```

GS9 and GS12 are writing, not code, and either would have changed how the two
surveyed sites were built. GS7 and GS8 are one item: a snippet library without
its CSS is a snippet library. GS10 and GS11 are what make the rest safe to use.
