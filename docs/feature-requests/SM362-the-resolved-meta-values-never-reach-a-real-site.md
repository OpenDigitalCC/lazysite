---
title: "SM362 - the engine resolves two meta values that no real site ever renders"
subtitle: "`page_meta_title` and `page_meta_desc` are resolved and frozen before a layout runs. All 23 catalogue layouts overwrite both, so an author setting `meta_title` in front matter changes nothing on any site using a shipped layout."
brand: plain
status: candidate
handover-note: "HANDED OVER 2026-08-17 to lazysite-layouts/inbox/2026-08-17-three-engine-findings-that-land-here.md, with SM349 and the SM337 lint - one fixture answers all three. The DOUBLE-ESCAPE is flagged there as the item to do first: it is not an absence but actively wrong output, on every page of every site using a shipped layout, in the one field whose purpose is to be read by something other than a browser, and it is a one-character fix per layout. Stays CANDIDATE here because nothing in the engine repository closes it - the engine tree ships no site layout to fix or to render in a lint."
status-note: "FILED 2026-08-17 from catalogue material handed to the inbox by the site agent, who found it in the layouts repository - one document on an unmerged branch and one untracked, both invisible to anyone reading that repo normally. Filed HERE although the fix is in the catalogue, because what is broken is an ENGINE CONTRACT: lazysite implements a feature, freezes two values for layouts to use, and every shipped layout ignores them. A capability that exists and cannot be reached is the same defect class as a control that reports without acting - [[SM337]] is the same shape for navigation, and this is a second instance from the same survey."
---

# The contract, and what happens to it

The engine resolves two values before a layout renders:

```
page_meta_title  =  meta_title  //  title
page_meta_desc   =  meta_desc   //  subtitle
```

An author sets `meta_title` or `meta_desc` in a page's front matter to control
what search engines and social cards show, separately from the heading on the
page. That is the documented way to do it.

**All 23 catalogue layouts overwrite both**, counted across the catalogue on 15
August 2026. So on any site using a shipped layout, setting `meta_title` does
nothing at all - and nothing says so. The page renders, the field is accepted,
the value is resolved, and it is discarded by the last thing to touch the
output.

# Why this is filed against the engine

The fix is in the layouts and the layouts are a different repository. What is
filed here is the contract: **lazysite implements a feature that cannot be
reached from any site built the normal way.**

[[SM300]] fixed the engine half of this and its own status note records the
qualification - the injection defers to a layout that has already emitted a
description tag, which is the right way to defer, and means the feature works
only when no layout is involved. That qualification is now measured: it is not
"some layouts", it is all of them.

[[SM337]] is the same shape for navigation - `nav.conf` is the documented way to
give a site its menu, and one layout of 23 renders it. Two capabilities, one
survey, the same failure: the engine is right and unreachable.

# The double-escape, which is a live defect rather than an absence

Recorded in the same handover and worth separating out, because it is not a
missing feature but a wrong output:

**Every layout applies `| html` to `page_subtitle` in its description tag.** The
value is already escaped by the time a layout sees it, so ordinary copy is
escaped twice: *a client\'s brief* reaches search engines as `a client&#39;s
brief`.

That is on every page of every site using a shipped layout, in the one field
whose entire purpose is to be read by something other than a browser.

# What would settle it

State the contract where layouts are written
: a layout must render `<head>` FROM the resolved values, not over them. It is a
  one-line rule and there is currently nowhere it is written that a layout
  author reads.

Assert it rather than describing it
: [[SM337]] proposes a lint that renders each shipped layout with a known body
  and asserts what comes out. The same harness answers this question - render a
  page whose `meta_desc` differs from its `subtitle`, and check which one
  reaches the `<head>`. One fixture, both defects.

Fix the double-escape first
: it is smaller, it is unambiguous, and unlike the rest it is actively wrong
  rather than merely inert.

# Where the material is

Both source documents are in `inbox/archive/2026-08-17-layouts-catalogue/`,
copied out of the layouts repository by the site agent without modifying it. The
catalogue briefing they accompany lives on an unmerged branch there
(`claude/catalogue-modernisation-briefing`), which is why neither was visible to
anyone reading that repository normally.

**Zero of 23 layouts declare a favicon** is recorded in the same handover. The
operator has called that immaterial and it is; it is noted here so the catalogue
fact has somewhere to live rather than being rediscovered.

# Related

[[SM300]] (the engine half, correct and deferring correctly), [[SM337]]
(activation reports a success it cannot back - the same shape for navigation),
[[SM349]] (the catalogue half of SM337, with numbers), and the handover in
`inbox/archive/2026-08-17-layouts-catalogue/`.
