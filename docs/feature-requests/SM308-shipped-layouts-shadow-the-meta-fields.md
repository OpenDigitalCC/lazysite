---
title: "SM308 - the shipped layouts shadow meta_title and meta_desc"
subtitle: "SM300 is correct in the engine and has no observable effect on any site using a layout, which is every site. A field frozen by ADR 0008 and implemented last release still does nothing."
brand: plain
status: shipped
status-note: "CLOSED 2026-08-19 - BOTH HALVES CONFIRMED, and confirmed from two directions because neither alone would have settled it. THE CATALOGUE HALF (lazysite-layouts, its own repo and release cadence) reports 23 of 23 layout.tt now rendering page_meta_title in <title> and page_meta_desc in the description, zero remaining titles from page_title, and zero `| html` filters on any of the five engine-escaped page_* variables - landed via their reviewed claude/catalogue-contract branch. Their lint went further than the proposal asked: t/site-contract.t RENDERS every layout with Template Toolkit against an engine-faithful stash and asserts the head contract plus the absence of double-escaping, rather than matching source text. THE FIELD HALF, which is how this was originally found: the site agent measured edge/0.10.15 on the shipped lumen layout with all four fields deliberately distinct - meta_title wins in <title> AND in the og/twitter share cards, meta_desc drives the description, title/subtitle keep doing their own job in the body. Two controls were run and both matter: a page with NO meta_* still falls back to title and subtitle, so the fix did not break the fallback; and an apostrophe arrives as &#39; and not &amp;#39;, so the double-escape wart the contract note predicted is not shipping. HONEST LIMIT ON THE FIELD EVIDENCE: the site agent tested ONE layout, not 23, because swapping the active layout on a live site to sample others would take it through several visible changes for a read-only question. So the set is covered by the catalogue repo's grep + rendering lint, and the field measurement confirms one member of it end to end. THE ENGINE HALF shipped earlier: the layouts briefing gained a 'The <head> contract' section, the worked examples in ai-briefing-layouts.md, layouts.md and features/configuration/views.md were corrected (they showed page_title, which is why all 23 layouts did), and t/lint/48 fails if any shipped example regresses, shown to fail on the pre-fix tree. ORIGINALLY FILED 2026-08-15 from a partner-agent field test of 0.10.9 on edge; this is the second half of SM300, not a regression of it."
---

# SM308 - implemented, frozen, and inert

## What was found

Measured on 0.10.9 through the installed `lumen` layout:

```datatable
columns: Page front matter | meta description emitted | title emitted
widths: 5.4cm | 5.4cm | X
bold: 1
tone: medium
---
`meta_desc` only | `meta_desc` (correct) | title, and `meta_title` ignored
`subtitle` + `meta_desc` + `meta_title` | `subtitle`, and `meta_desc` ignored | title, and `meta_title` ignored
`subtitle` only | `subtitle` (correct, unchanged) | title (correct)
---
```

**The engine is right.** `lazysite-processor.pl:5341` resolves `meta_desc //
subtitle` and `meta_title // title`, and `scan_pages` does the same for the
registries - which is why the generated `llms.txt` carries the right description
while the page it points at does not. The processor injects `page_meta_desc`
only when the rendered HTML carries no description tag already (`:5991`), which
is the correct way to defer to a layout.

The layout then does this:

```html
<title>[% page_title %][% IF site_name %] - [% site_name %][% END %]</title>
[% IF page_subtitle %]<meta name="description" content="[% page_subtitle | html %]">[% END %]
```

So a layout that emits its own description from `page_subtitle` wins, and
`page_meta_title` is never consulted by any layout that writes its own `<title>`
- which is all of them, because writing your own `<title>` is the ordinary way to
write a layout. The effect is not confined to `lumen`.

## Why this is worth its own filing

**A frozen field with no behaviour behind it is the exact thing t/lint/45
exists to stop.** That lint was added in 0.10.9 because ADR 0008 named
`meta_title` and `meta_desc` as frozen while neither existed anywhere in the
codebase. Implementing them satisfied the lint - the processor now reads both, so
the haystack matches - and `meta_title` still has no observable effect on any
real page. The lint asserts the field is *read*; it cannot assert the value
*reaches the output*. The promise ADR 0008 makes is about what a site author
observes, and that promise is still unmet.

**The registries and the page now disagree.** `llms.txt` advertises a page with
its `meta_desc`; the page itself serves its `subtitle`. Two parts of one release
describe one page differently, which is the shape SM307 is filed for elsewhere.

**It is invisible from the repository.** Every test that could catch this renders
through the engine, where the behaviour is correct. It was found by fetching a
page from a deployed site and reading the `<head>`.

## Scope, measured

The catalogue is a separate repository (`/srv/projects/lazysite-layouts`) on its
own release cadence. Counted there on 2026-08-15:

```datatable
columns: Of the 23 catalogue layouts | Count
widths: 9cm | X
bold: 1
tone: medium
---
emit their own `<title>` | 23
emit their own `<meta name="description">` | 23
consult `page_meta_title` | 0
consult `page_meta_desc` | 0
derive the description from `page_subtitle` | 22
---
```

So the answer is not "some layouts shadow the fields". Every layout does, and
the two fields have no effect on any site using any of them - which is every
site. `lumen`, the one the field test measured, is representative rather than
unlucky.

**This splits across two repositories, and the split decides the order.** The
code fix belongs in the layouts catalogue. The engine repo holds the briefing
that tells a layout author what the contract is, and that is the part which must
land first: fixing 23 layouts against an unstated contract leaves the 24th to
reproduce the defect. Write the contract, then fix the catalogue against it.

## The double-escape, carried over from SM362

Separate from the contract above, and the item to do FIRST because it is not an
absence but a wrong output.

**Every layout applies `| html` to `page_subtitle` in its description tag.** The
value is already escaped by the time a layout sees it, so ordinary copy is
escaped twice: *a client's brief* reaches search engines as
`a client&#39;s brief`.

That is on every page of every site using a shipped layout, in the one field
whose entire purpose is to be read by something other than a browser. Unlike the
rest of this filing it is actively wrong rather than inert, and it is a
one-character fix per layout.

Recorded here rather than in [[SM362]] because that filing is superseded by this
one, and a superseded filing that still owns a live item is the same ambiguity
in a different shape.

## The fix

Teach the shipped layouts to read the resolved fields
: `page_meta_title` and `page_meta_desc` are already provided to the template.
  Each shipped layout's `<title>` and description tag should prefer them and fall
  back to what it uses today, so an existing site is unchanged and a page that
  sets the fields is honoured. This is a small edit per layout file and changes
  no engine code.

Lint that they do
: the same shape as t/lint/45 and t/lint/36 - walk every shipped layout, and for
  each one that emits a `<title>` or a `<meta name="description">`, assert it
  consults the resolved variable. A layout that hard-codes `page_subtitle` into a
  description tag is the defect, and a walk finds it in every layout rather than
  the one that was checked by hand. Note the t/lint/46 lesson: walk the tree,
  do not glob one level of it.

Say what a layout author must do
: the layouts briefing should state that `page_meta_title` and `page_meta_desc`
  are the resolved values and a layout that ignores them silently overrides the
  page's front matter. A third-party layout will otherwise reproduce this, and
  the engine deliberately cannot stop it - deferring to the layout is the
  designed behaviour.

## Verification

Shown to fail first, on a layout-rendered page rather than a bare render:

- a page with `meta_title` set emits it in `<title>` through every shipped
  layout;
- a page with both `subtitle` and `meta_desc` emits `meta_desc` as the
  description;
- a page with `subtitle` only is byte-identical to today, on every shipped
  layout - this is the compatibility half and matters more than the feature half;
- the lint fails on a layout that writes a description from `page_subtitle`
  without consulting `page_meta_desc`.

## Related

SM300 (the engine half, shipped in 0.10.9), ADR 0008 (which freezes both fields),
t/lint/45 (which asserts they are read), t/lint/46 (the walk-the-tree lesson).
