---
title: "SM320 - render a layout and assert what actually comes out"
subtitle: "A layout is the last thing between the engine and the visitor, and it was the only major component with no behavioural test"
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.10 as t/integration/55. Asserts the ENGINE half of the contract: nav with children, page body, resolved meta_title/meta_desc, and escaped exactly once. VERIFIED against the defect - putting `| html` back into the fixture layout makes it fail with 'isn&amp;#39;t', the field symptom exactly. Nomination 1 of four, the one the site agent said to take if only one was taken. DELIBERATELY SCOPED: there are no catalogue layouts in this repository, so a test claiming to check 'every shipped layout' would be checking an empty set and reporting a pass - which is the defect this programme exists to remove."
---

# The gap

`t/integration/13` compiles layouts. `t/lint/32` checks the manager guide covers
the nav. Nothing rendered through a layout and looked at the result, and one week
of field work produced four filings that all live there:

- no layout renders `nav.conf`
- layouts render demo content in place of the page body
- every shipped layout double-escapes the description
- `meta_title` / `meta_desc` are shadowed, so SM300 reaches almost nobody

# What it asserts, and what it cannot

The **engine's** half: that a layout is offered everything it needs to be
correct, in the form the contract promises - `nav` with children, `content`, the
resolved `page_meta_title` and `page_meta_desc`, and those values escaped exactly
once.

The escaping assertion decodes once and requires the author's characters back,
which is the check that would have caught the double-escape across every shipped
layout at once.

Whether a given catalogue layout **uses** what it is offered is the layouts
repository's assertion to make, and the proposal filed there says so. Claiming it
here would mean checking an empty set and reporting a pass, which is the shape
this whole programme is about.

# The fixture is the worked example

Deliberately minimal and correct. If the engine's side regresses, this fails; if
it does not, an author copying this shape gets a working layout.

# Related

SM300 (the meta fields), SM308 (which found them shadowed), SM312 (the escaping
contract), and the layouts-repo proposal carrying the catalogue half.
