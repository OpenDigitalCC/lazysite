---
id: SM1342
title: "SM1342: a /docs anchor lands on its heading"
subtitle: "The manual wrote its section links as GitHub-style anchors (#the-docs-manual), and the engine's converter ids a heading with no hyphens for spaces (#thedocsmanual), so eight links in the shipped manual landed at the top of their page. They are written in the engine's form, and a lint holds every anchor to a heading."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "the developer agent, checking SM1341's links and anchors as ruling 80's brief asked"
area: docs
status-note: "SHIPPED (0.16.5) on n749: eight anchors rewritten; t/lint/310."
---

# What was found

SM1341 points one page at a section of another more than the manual did before, so
its links were checked anchor by anchor, as the brief asked. Lint 290 holds every
/docs link to a page the engine serves and leaves the fragment out.

The engine renders Markdown with Text::MultiMarkdown, which ids a heading by
lower-casing it and keeping only letters, digits, `:`, `_`, `.` and `-`
(`_Header2Label`): `## The /docs manual` is `id="thedocsmanual"`. The manual's anchors
were written as GitHub writes them, `#the-docs-manual`, which no heading carries, so
the browser stays at the top of the page. Eight on the base:

- index.md and configuration.md: `#the-docs-manual`
- configuration.md (twice): `#domain-aliases`
- ai-briefing-layouts.md: `#multi-domain-instances`
- install.md: `#if-something-is-wrong-and-the-version-is-not-changing`
- reference.md: `visitor-ip#asking-whether-the-address-is-on-a-list`
- features/authoring/visitor-ip.md: `#behind-a-reverse-proxy`

A ninth is in ai-briefing-practice.md, `#handing-out-work-to-several-people-at-once`.
That page is generated from sources outside this repo and lint 89 refuses an edit to
the served copy, so it is fixed at the source.

# What shipped

- The eight anchors are written in the engine's form. The index and layouts-briefing
  ones went in with SM1341's rewrite of those pages, the other six here.
- Every anchor SM1341 adds is in that form.

# Tests

- **t/lint/310** (new): every Markdown link and href in the manual whose target is a
  /docs page with a `#fragment`, or a bare `#fragment` on the same page, names a heading
  of that page under `_Header2Label`'s rule. Code is left out, as in lint 290. The
  practice page's one anchor is named, and the lint fails if it changes or another
  appears.

Against the base's docs the lint names all eight. The engine's ids were read from a
rendered page (t/lib's run_processor) before the rule was written down.

# Open

- The practice page's anchor needs fixing in its source (tools/import-field-practice.pl
  imports it); lint 310 will then fail on the named exemption, which is to be removed.
