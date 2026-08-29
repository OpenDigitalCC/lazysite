---
id: SM689
title: An HTML comment silently discards the markup around it
raised: 2026-08-29
raised-by: release manager
area: rendering
status: shipped
status-note: "SHIPPED in 0.11.6. Text::MultiMarkdown pairs `<!--` with a LATER `-->` when hashing HTML blocks and DISCARDS everything between - not escaped, gone. Measured on the Data page: 20 of its 46 elements never reached the browser, including `rows-panel`, which surfaced to the operator as 'Could not load rows: can't access property style, panel is null'. The page source was correct and every source-level test passed, because the loss happens between the source and the browser. Fixed by protecting comments from the markdown pass the same way `<script>` and `<style>` already were - the processor's own comment describes this exact failure mode for styles."
---

# What the operator saw

On the Data page of 0.11.5:

> Could not load rows: TypeError: can't access property "style", panel is null

The script was looking for `#rows-panel`. The page source defines it. The
browser never received it.

# Why

`Text::MultiMarkdown`'s HTML-block hashing pairs a `<!--` with a **later**
`-->` and discards what lies between. A page that explains itself in comments
between its markup loses that markup - silently, with no error raised anywhere,
at a stage no test was watching.

The processor already knew about this failure mode for a neighbouring case. The
comment above the existing protection says so:

> comments pairs into `<em>...</em>`, swallowing the rules in between (the
> login page's inline styles regressed exactly this way)

`<script>` and `<style>` were protected. Comments were not.

# How much was lost

Measured across every manager page by rendering each one and checking that
every `id` its own script fetches survives:

| Page | Elements lost |
| --- | --- |
| `starter/manager/data.md` | **20 of 46** |
| every other manager page | none |

Contained to one page, and total on that page: `rows-panel`, `rows-table`,
`import-panel` and the whole ACL panel among them. Recovered in full by the fix.

Data is the page it hit because it is the page that explains itself most: DM-4
on staged imports, DM-5 on editing the descriptor as text, SM680 on the rows
modal. The more carefully a page was documented, the more of it was destroyed.

# Why the tests did not catch it

Every test of this page reads the SOURCE. The source was correct throughout -
correct markup, correct ids, correct script. The loss happens in the render, so
a source-level test cannot see it, and there was no test rendering a manager
page and asking whether its elements survived.

This is the second defect in two days from the same gap. SM687 was a UI built
on a verb that refused; this is a UI built on markup that never arrived. In
both, everything anyone thought to assert passed.

# The fix

Protect `<!-- ... -->` from the markdown pass exactly as `<script>` and
`<style>` are protected: hash it to a placeholder, run markdown, restore it.
The matcher then never sees a `<!--` to mispair. Comments reach the output
verbatim, which is what an HTML comment in a page is for.

# What still is not covered

The regression test renders `data.md` and asserts its elements survive, and it
uses the REAL page as the reproducer on purpose - a hand-written minimal case
does not reproduce this, because the mispairing needs enough interleaved blocks
and comments to reach past one block to a later `-->`. That is why the defect
survived every minimal test anyone would have written.

**DONE in 0.11.6+**: `t/lint/94-a-page-keeps-the-elements-its-script-fetches.t`
renders every manager page and asserts that every `id` the page declares AND its
own script fetches by name survives. The dependency list is derived from the
`getElementById` calls rather than maintained by hand, so it cannot drift from
what the page actually needs.

Verified against the defect it exists for: removing the comment protection makes
it fail and name `import-panel`, `import-file` and the rest of what the Data
page was losing. What was still missing was the general form: a lint that
renders EVERY manager page and asserts that every `id` its script fetches by
name reaches the output.
That would have caught this, and would catch the next thing that eats markup
for a different reason. Filed as the remaining work here rather than built,
because it needs a way to enumerate the ids a page's script actually depends on.

# Related

[[SM687]] (the other half of the same Data page, broken a different way),
SM680 (the rows modal, whose markup this was destroying), SM635.
