---
title: "SM493: a standard component set, with its CSS, and a components-list on the control API"
subtitle: "Refiled from SM492 (GS7, GS8, GS10). The mechanism is documented and an unclosed fence is named; what is still missing is anything to reach for"
brand: plain
standard-margins: true
status: candidate
status-note: "REFILED 2026-08-23 from SM492, whose writing and safety items (GS9, GS11, GS12) shipped in 0.10.28. Three remain, and they are one piece of work: GS7 a standard component set (hero, band, stats, cards, gallery, media, quote, cta, logos, video) in the any-layout directory; GS8 each with its own CSS written against theme tokens and mirrored with the theme at activation - a snippet library without its CSS is a snippet library; GS10 a components-list on the control API (name, attributes, slots, origin) so an agent can discover what a layout offers instead of guessing. SIZE L. Gated on nothing; waits for the first site that asks, because a component set designed without a consuming site is a guess about what sites want. The survey evidence is in inbox/archive/2026-08-22-graphics-led-sites-the-mechanism-exists-and-nobody-can-reach-it.md."
---

# Why this is its own filing

SM492 had six proposals. Three were writing and a small check, and they shipped
together; three are a design job with a CSS contract and an API surface, and
they are not small. Leaving them as the unfinished half of a shipped filing is
how items get forgotten, so they live here.

# The three items

```
GS7  | Ship a standard component set in the any-layout directory            | L (with GS8)
GS8  | Give each shipped component its own CSS, against theme tokens,        | L (with GS7)
     | mirrored with the theme at activation                                 |
GS10 | `components-list` on the control API: name, attributes, slots, origin | S
```

GS7 and GS8 are one item. GS10 is what makes GS7 discoverable without reading
the layout directory, and is the natural home for `validate_page`'s
`component-fence-unmatched` to say "and the components this layout DOES
offer are ...".

# What already exists (so this does not re-invent it)

- `::: name` fences, `attrs`/`content`/`slots`, nesting, built-in fallback
  under `lazysite/templates/components/` - documented in
  `ai-briefing-layouts` since SM492.
- `sections:` parsed into a `sections` TT variable; no shipped layout reads
  it. A component set is the moment a shipped layout should.
- Theme assets mirror at activation (SM-asset-mirror) - the CSS for a shipped
  component goes through the same door.

# Open design question, for the first consuming site

Whether the set lives in `lazysite/templates/components/` (available to every
layout, styled by a shared CSS file the theme overrides) or in a reference
layout (styled by that layout's theme, copied by others). The built-in `qr`
took the first route because it needs no styling. A hero needs styling, which
argues for the second - or for the first with a token-only stylesheet.
