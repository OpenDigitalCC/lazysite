---
title: "SM086 - Pandoc-wrapper construct renderers"
subtitle: "Bring the rich pandoc-markdown constructs into lazysite HTML output"
brand: plain
---

::: widebox
The house pandoc-markdown pipeline (Lua filter + Eisvogel template -> branded PDF)
adds rich authoring constructs - `datatable`, `piechart`/`barchart`, `:::` callout
boxes, definition lists, footnote citations. Explore that pipeline and give
lazysite HTML renderers for the same constructs, so content authored once renders
in both the PDF pipeline and on the site.
:::

## Tasks

1. **Explore pandoc-wrapper**: catalogue every construct the Lua filter provides
   (fenced `datatable`, `piechart`, `barchart`; `:::` boxes - widebox, examplebox,
   marginbox, textbox, recommendation, box-policysummary, budgetbox; definition
   lists; `^[...]` footnote citations; letter/featured/slides templates) and the
   options each takes.
2. **Map to lazysite**: which already have a lazysite equivalent vs which are new.
   - `:::` boxes overlap with the existing `convert_fenced_divs` (widebox, textbox,
     marginbox, examplebox) - align names + styling so authored content matches.
   - `datatable`, `piechart`, `barchart` have no lazysite renderer yet.
3. **Build renderers**: HTML (+ inline SVG/CSS) renderers for the missing
   constructs - a `datatable` fenced block -> a styled HTML table; `piechart` /
   `barchart` -> SVG/CSS charts; footnote citations -> a references section.
   Themeable via the active layout's CSS variables.
4. **Capability matrix**: document which pandoc-wrapper capabilities lazysite
   supports, partially supports, or intentionally omits (e.g. print-only
   letter/featured templates), so an author knows what travels to the web.

## Notes

- The skill reference lives at the user's pandoc-markdown skill folder
  (REFERENCE.md) and `pandoc/documentation/`.
- Keep it incremental: the boxes/definition-lists/citations are the high-value,
  low-risk first set; charts are the bigger build.
- A shared construct vocabulary means an author can write one Markdown source and
  publish it as a branded PDF and a web page.

## Status

Queued (design/exploration). Raised 2026-06-25.
