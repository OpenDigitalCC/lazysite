---
id: SM1254
title: "SM1254: a quoted page variable is its contents"
subtitle: "A tt_page_var entry kept its quote marks, so a quoted list reached the layout with a quote on its first and last items. It is read as a top-level key is now."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: the lazysite.io site agent, inbox 2026-10-22-forms-validator-and-page-var-quotes.md (K-3)
area: processor
status-note: "SHIPPED (PENDING) on n728: parse_yaml_front_matter takes one matched pair of quotes off a tt_page_var value; t/unit/processor/150."
---

# What happened

`parse_yaml_front_matter` (lazysite-processor/front-matter.pm) read a
`tt_page_var:` entry with `^[ \t]+(\w+)\s*:\s*(.+)$` and stored the value as
written. A top-level key goes through `_front_matter_scalars`, which takes one
matched pair of `"` or `'` off; the block entry did not.

Reproduced from the code: `hero_cards: "a,b,c"` reached the layout as
`"a,b,c"`, with BOTH quotes. The report saw the opening one because its layout
split the list and printed the first item, `"a`; the last item was `c"`.

# What shipped

A `tt_page_var` value has trailing space trimmed and one matched pair of quotes
removed, the same rule as `_front_matter_scalars`. An unquoted value, quotes
inside a value and an unmatched quote are unchanged.

A quoted value is now its contents before the source prefixes are read, so
`x: "json:/data/x.json"` binds the JSON file as `x: json:/data/x.json` does.
That is what the YAML means, and an author who can write one can write the
other.

# Tests

t/unit/processor/150: double- and single-quoted values, one with a colon and
trailing space, an unquoted value, inner quotes, an unmatched pair and a lone
quote, read by `parse_yaml_front_matter`; and a page rendered under a layout
that splits the value, whose first and last items are `a` and `c`. With the old
front-matter.pm, the three quoted cases and both render assertions fail.
