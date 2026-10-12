---
id: SM1037
title: "SM1037: the nav docs describe the format the parser reads"
subtitle: "The configuration docs said the nav file is YAML. parse_nav reads `Label | /url` lines, so a nav written from the doc rendered as labels with no links."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 P23 (SM997), found while building; ruling of 2026-10-12
area: docs
status-note: "SHIPPED (PENDING): configuration.md and ai-briefing-configuration.md give the line format parse_nav reads - Label | /url, a bare label a heading, children indented, one level, # comments - in place of a YAML format no reader parses (t/tools/140)."
---

# The ruling

Found while building SM997 and recorded in WORK-PLAN-0154: starter/docs/
configuration.md described the nav as YAML (`- label: ... url: ...`, with
`children:`), and `parse_nav` reads only `Label | url` lines (what the doc
called the "legacy pipe format"). Correct the doc, or teach the parser YAML?
The release manager ruled, in these words, "Fix both" (with the filings' `id:`,
P22): correct the doc to the real format - `Label | /url`, children indented,
`#` comments - matching the n490 skill note (SM887's site-context.md) and
`parse_nav`.

# What was wrong

A nav file written from the doc's example parses, line by line, as headings:
`- label: Home` has no `|`, so it is an item labelled `- label: Home` with no
address, and the indented `url: /` under it is a child labelled `url: /`. The
site renders a menu of labels that link nowhere. The YAML was never read by any
release; the "legacy" format was the only one. starter/docs/
ai-briefing-configuration.md, the agent briefing for the same topic, carried
the same YAML example.

# What changed

Both docs' Navigation section gives the line format with an example and the
rules `parse_nav` (lazysite-processor/sources.pm) applies, as SM887's skill note
states them: split at the first `|`; a line with no `|` is a heading; a line
that starts with whitespace is a child of the nearest top-level line, one level
only; an orphan child is top-level; `#` as the first non-blank character is a
comment; a line with no label is dropped; UTF-8. The briefing says the format
is not YAML and that `set_nav` takes the items as a structure and writes it.
The "Legacy pipe format" heading is gone: it is the format.

# Tests

t/tools/140: each doc's example parses with `parse_nav` to the links, the
heading and the children it shows; neither offers a YAML list or a YAML block;
each rule configuration.md states is checked against the parser. Against the
docs as they were (n414) it fails all three subtests. Sabotage (restored by cp,
checked by cmp, tmp/sab-bak/SM1037/): a child left unindented in the example
fails it; a YAML example put back in the briefing fails it.
