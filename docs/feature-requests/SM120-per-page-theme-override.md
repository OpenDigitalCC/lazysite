---
title: "SM120 - per-page theme: preview override"
subtitle: "Make theme symmetric with layout - the highest-leverage theming fix"
brand: plain
---

::: widebox
A page can override its **layout** in front matter (`layout:`, preview-only); it cannot
override its **theme**. That asymmetry forced a theme-explorer build to bake each theme
into a self-contained demo layout - which cuts against the D013 rule that layouts carry
no colour/font. A preview-only `theme:` front-matter key (symmetric with `layout:`,
sanitised the same way) turns "show five themes at once" or "preview a candidate theme"
into one-line pages on the real layout, with no scaffolding.
:::

## From the field report

"Layouts can be overridden per page; themes cannot. That asymmetry is the one gap that
shaped the whole explorer build... a `theme:` override would make a theme explorer a
handful of one-line pages on the real default layout - no scaffolding layouts at all.
It would also give theme authors a way to preview a staged theme on a single page
before activating it globally." Rated **High impact, Low effort** - the single
highest-leverage fix.

## Shape

- A `theme:` front-matter key, **preview-only** (never how you ship a design - that is
  the activated theme), mirroring `layout:` exactly: same resolution, same value
  sanitising, same "only renders if compatible with the active/overridden layout".
- The processor selects the page's theme assets from the override when present, else
  the active theme. The asset mirror already persists per (layout, theme), so the CSS
  is available once the theme has been activated at least once (see [[SM123]]).

## Status

Queued. Small and self-contained per the report; mirrors the existing layout-override
path in the processor.
