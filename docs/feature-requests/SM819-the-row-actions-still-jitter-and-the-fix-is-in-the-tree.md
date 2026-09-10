---
id: SM819
title: "SM819: the row actions still jitter, and SM807's fix is in the build that was tested"
subtitle: "1310E-04 measured four connector rows whose action group spans 297px, and reports `.mg-row-actions` computing `margin-left: 0`. But `margin-left: auto` was added by SM807 in 1b902ecb, which IS in 0.13.10 - so either the served stylesheet predates the fix, or a second cause is at work. One request settles which, and the same suspicion explains SM820: an asset mirror that an upgrade did not refresh."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-10
raised-by: sites agent
area: manager-ui
---

# The measurement

Four connectors with deliberately varied URL lengths, `.mg-row-actions` left edge:

    longer  x=497    medium  x=623    short  x=773    tiny  x=794

297px of spread - wider than the 130px recorded in 139E because a wider range of
URL lengths was chosen. The credential group descends the list diagonally.
Reported computed values: the row is `display: grid` with
`grid-template-columns: 376.7px 563.3px`, differing per row, and
`.mg-row-actions` has `margin-left: 0` with `flex: 0 1 auto`.

# Why that is confusing, and what it points at

**`margin-left: auto` is in the tree, and it shipped in the build under test.**
`git log -S` puts it in `1b902ecb` - SM807 - which landed in 0.13.10. All three
stylesheets carry it identically at line 580:

    .mg-row-actions { display: flex; gap: 6px; align-items: center; margin-left: auto; }

Nothing else in any sheet sets a margin on that class, and no page sets one
locally. So a computed `margin-left: 0` on 0.13.10 should not be possible from
these sources.

**The likeliest explanation is that the served stylesheet is not this one.** The
manager layout links it as
`/manager/assets/manager-[% manager_style %].css?v=[% lazysite_version %]`, so
the query defeats browser caching - but only if the FILE behind that path was
refreshed. `/manager/assets/` is a copy of the engine's
`starter/lazysite/manager/assets/`, and if an upgrade leaves the copy in place
the browser is served the old bytes at a new URL.

That is the same shape [[SM808]] guessed at for `layout.tt` and was wrong about -
but here there is a measurement that does not otherwise reconcile, and
**[[SM820]] independently found an asset mirror that an upgrade does not
refresh.** Two findings from one test run pointing at stale mirrors is worth
more than either alone.

## The one request that settles it

Fetch `/manager/assets/manager-modern.css` from edge and grep for
`margin-left: auto` on `.mg-row-actions`. Present means the CSS is being served
and the cause is elsewhere; absent means the fix shipped and is not reaching the
browser, and this filing becomes an asset-refresh defect rather than a layout
one. Asked of the sites agent.

# The second, latent cause - real either way

**The connectors row puts three cells in a two-column grid.** `.mg-row` is

    display: grid; grid-template-columns: minmax(0, 1fr) auto;

and `connectors.md` renders `.mg-row-name`, then a separate top-level
`.mg-row-meta` carrying the URL, then `.mg-row-actions` - three grid items in a
two-column template, so the third lands in an implicit content-sized column.
`backups.md` does the same.

**And the style guide's exemplars show three cells too** - four `.mg-row-name`,
four `.mg-row-meta` and five `.mg-row-actions` across its demos. So if three
cells is wrong, the guide is teaching it, which is exactly [[SM816]]'s shape and
the second time in two days that the exemplar is the source.

This wants deciding rather than patching, because the two readings lead opposite
ways:

- **Three cells is the intended shape** and the CSS is wrong: the template needs
  a third column with the FLEXIBLE one in the middle, so the actions column is
  the last and sits at the row's right edge on every row -
  `minmax(0, auto) minmax(0, 1fr) auto`.
- **Two cells is the contract** and the pages and the guide are wrong: the meta
  belongs inside the first cell, which is what `.mg-row .mg-row-meta { display:
  block }` at line 565 appears to exist for.

**Not built, deliberately.** Either fix changes every `.mg-row` on every manager
page across three stylesheets, and its effect is visual and cannot be verified
from here - no test in the suite measures a computed x position. Shipping an
unverified layout change across the whole manager to fix a jitter would risk more
than it fixes. It wants the one request above first, because if the served CSS is
stale then neither change is the fix.

# What 1310E-04 otherwise found

Three of four steps passed, and one of them is worth recording as a deliberate
difference rather than a gap: **the remedy's LINK is present for an account that
can grant and absent for one that cannot.** The ref asked for it
unconditionally; the reporter read the absence as right, and it is - sending an
account to a page where it can do nothing is worse than not linking. [[SM807]]'s
wording change works as intended: "You can grant it on the Groups page" against
"A user manager can grant it on the Groups page".

# Provenance

`inbox/2026-09-10-1310E-results-0.13.10.md`, ref 1310E-04. The measurements are
the reporter's; the `git log -S` attribution, the three stylesheets, the absence
of any competing margin rule, the three-cell row shape and the guide's exemplars
were read here.

# BUILT 2026-09-10, and the mechanism was not what this filing guessed

**The prior art was on main and this filing did not find it.** Third time in one
session, after SM818 duplicating [[SM222]]. The register lives at `docs/review/`
- singular - and the search looked in `docs/reviews/`.

- **MR-53 is the release manager's own decision** on this exact question: grid
  rows, "everything that describes the row, then everything that acts on it".
- **MR-68 is this same defect, weeks earlier, on the Plugin Manager**: "Those
  rows have THREE parts ... in a two-column grid, so the third wrapped to an
  implicit row and the text ran over the checkbox." It was fixed there by using a
  three-column template, and the shared row kept the fault.

## The mechanism, which reconciles the measurement completely

With two columns declared and three cells present, the third cell does **not**
fall into an implicit COLUMN. It wraps to an implicit **ROW** at column 1, where
`.mg-row > :last-child`'s `justify-self: end` right-aligns it inside a column
whose width is whatever the metadata left over. So:

    longer URL  -> wider metadata column -> narrower column 1 -> smaller x
    tiny URL    -> narrow metadata column -> wider column 1   -> larger x

which is exactly the reported 497 / 623 / 773 / 794.

**And `margin-left: 0` was never evidence of a stale stylesheet.**
`margin-left: auto` resolves to **0** when the grid area has no free space - so
SM807's fix was present, being served, and inert. The reporter read the computed
0 as the property being unset, which was a reasonable inference and the wrong
one; the suspicion of a stale asset was mine and it was wrong. **The question
put to the sites agent is withdrawn** - no request is needed.

## What was built

`.mg-row` is `minmax(0, 1fr) auto auto` in all three stylesheets - the release
manager ruled for three columns rather than folding the metadata into the first
cell, which also matches MR-68's remedy. No page changed: `connectors.md` and
`backups.md` were already supplying the three cells the template now has.

`t/lint/124` asserts two things, because two things recurred here: that **all
three styles declare the same row** - a template that drifts in one style lays
rows out differently for whoever selected it, and nothing else would say so - and
that it declares **at least three columns**, counted rather than string-matched,
so a future edit may re-space it but dropping back to two has to meet this
argument. Verified by reverting one sheet to two columns and watching both
assertions fail.

The style guide now states the contract beside the idiom: a row is three columns,
supply at most three top-level cells.
