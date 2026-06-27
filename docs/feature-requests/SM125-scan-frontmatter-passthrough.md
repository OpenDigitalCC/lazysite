---
title: "SM125 - scan: custom front-matter passthrough + custom sort"
subtitle: "Self-describing registry cards without smuggling data through tags"
brand: plain
---

::: widebox
`scan:` page objects exposed only a fixed set of fields (url, title, subtitle,
date, tags), so a registry/gallery card had to smuggle custom data (a palette,
a demo slug, an order) through `tags` and the filename. Now every non-control
front-matter key passes through onto the page object, and any custom key is
sortable - so a card is self-describing.
:::

## What shipped (v0.4.46)

From a CC field report building a dynamic theme gallery (themes.explore.lazysite.io):

1. **Front-matter passthrough.** Any non-control front-matter key is exposed on the
   scanned page object under its own name: `[% t.kind %]`, `[% t.demo %]`,
   `[% t.accent %]`, `[% t.order %]`. Computed fields (url/title/date/tags/...) take
   precedence; control keys (`layout`, `theme`, `auth`, `register`, `search`, `tt_*`,
   `_*`) are excluded. Surrounding quotes are stripped (`accent: "#7C5CFF"` ->
   `#7C5CFF`, since a bare `# …` is a YAML comment) and TT markers are stripped for
   safety.
2. **`sort=<custom-key>`**, numeric-aware - `sort=order` gives 2 before 10, not lexical.
3. **Recursive `**` glob** (`scan:/gallery/**/*.md`) was already supported; now
   documented (the old "one level only" note was stale).

So a gallery becomes one recursive scan + `sort=order` + clean `[% t.kind %]` keys,
with no tags-hack or filename derivation.

## Tests / docs

t/unit/processor/03-resolve-scan.t (passthrough, quote-strip, numeric custom sort).
Documented in configuration.md (Page object fields / Sort order) and
ai-briefing-configuration.md.

## Status

**SHIPPED in v0.4.46.**
