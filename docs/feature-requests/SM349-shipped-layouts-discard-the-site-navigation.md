---
title: "SM349 - The shipped layouts discard the site navigation"
subtitle: "`manage_nav` is granted, `read_nav` and `set_nav` work on both surfaces, the engine stores the result - and on edge exactly one of eleven configured destinations reaches the rendered page. Three of the links that do render are hard-coded anchors into a demo homepage."
brand: plain
status: candidate
---

# SM349 - eleven configured, one rendered

## What was measured

edge 0.10.12, active layout `lumen`, homepage fetched anonymously and its
`<nav>` compared against `read_nav`.

```datatable
columns: Configured in nav.conf | Rendered on the page
widths: 7.4cm | X
bold: 1
tone: medium
---
Theme Explorer -> `/` | rendered
Feature demonstrator -> `/lazysite-demo` | ABSENT
Docs -> 7 children (authoring, features, api, configuration, reference, install, development) | ABSENT
Manager -> `/manager` | ABSENT
- | `Features` -> `#features` (hard-coded)
- | `Voices` -> `#voices` (hard-coded)
- | `Essay` -> `#essay` (hard-coded)
```

**One of eleven configured destinations renders.** The three extra links
are anchors into sections of the demo homepage, so on any page that is not
that homepage they point at nothing.

## Why this is the catalogue half of a defect that already has an engine half

[[SM337]] records the engine side: activating a layout that cannot render
the site reports success. This filing is the measurement of what that
success buys - and the two should stay separate, because fixing either
alone leaves the other standing.

[[SM337]] answers *"the activation should have told me"*. This answers
*"and here is what the layouts actually do"*. A warning on activation is
correct and insufficient if every layout in the catalogue earns the
warning.

## Why it matters

**A granted capability with two working surfaces produces nothing.**
`manage_nav` is granted. `read_nav` and `set_nav` are advertised MCP
tools. The control API honours the same actions. [[SM318]] did real work
to make both surfaces address a domain correctly and to fix the missing
cache invalidation. All of that is upstream of a front end that ignores
the result.

**The site's own documentation is unreachable from the site.** Seven doc
pages and the manager are configured in the navigation and appear nowhere
on the rendered page. A visitor can reach them only by knowing the URL.

**It silently converts a real site into a demo.** The hard-coded
`#features` / `#voices` / `#essay` anchors are the theme gallery's own
section links. Any operator who activates this layout gets a menu
advertising a page they do not have.

**It is the whole catalogue, not one layout.** Every layout on this
instance is a theme-gallery showcase with hard-coded links -
`atelier` ships "Works / About / Explorer", `consultancy` ships
"Meridian & Co". `list_layout_catalogue` gives no signal which entries are
showcases and which could carry a real site, which is why this is
discovered after activation rather than before.

## The fix

The layouts must render `[% nav %]`. That is the contract the `default`
layout already meets and the briefing at
`lazysite-layouts/docs/BRINGING-THE-CATALOGUE-UP-TO-DATE.md` sets out per
layout, alongside the other four things 22 of 23 catalogue entries are
missing - share cards, canonical, auth indicator, mobile control.

Two things worth deciding with it:

Mark showcases as showcases
: `list_layout_catalogue` should say whether an entry renders site
  navigation. An operator choosing a layout cannot currently tell, and
  finds out by activating it.

Fail the gate, not the operator
: a lint that renders each shipped layout with a known `nav` structure and
  asserts the labels appear would catch a regression and would have caught
  the whole catalogue.

## Verification

- Activating any shipped layout and setting a two-item nav renders both
  labels on a page that is not the homepage.
- No shipped layout emits a link to a fragment that exists only in its own
  demo content.
- `list_layout_catalogue` distinguishes showcase entries from
  site-capable ones.
- The lint fails on a layout template containing no `nav` reference.

## Related

[[SM337]] (the engine half - activation reports a success it cannot back),
[[SM318]] (one nav implementation, both surfaces, per domain - the work
this wastes), [[SM105]] (nav as its own capability),
`lazysite-layouts/docs/BRINGING-THE-CATALOGUE-UP-TO-DATE.md`, and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
