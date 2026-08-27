---
title: "SM337 - activating a layout that cannot render the site reports success"
subtitle: "Every signal said it worked. install_layout returned ok:1, activate_layout returned ok:1, nav-save reported the cache entries it cleared, nav-read returned the saved items, and the page returned 200. The navigation was simply absent, and 22 of the 23 layouts in the catalogue behave this way."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-17 - the engine half. `_validate_layout_dir` already had the template open, so the answer cost a regex: activation now reports `renders` for nav, content and the two resolved meta values, and WARNS when a layout has no `[% nav %]` - naming the consequence (\"nav.conf will have no effect\") rather than the absence of a directive. It does NOT refuse: activating a showcase is a legitimate choice, and a tool that refuses legitimate choices gets worked around. The catalogue half is [[SM349]], with the numbers - 1 of 23 layouts renders the navigation, and 1 of 11 configured destinations reached a page on the instrument. [[SM362]] rides the same read: every catalogue layout overwrites the resolved meta values, so those are reported too rather than needing a second survey."
---

# What was found

Three layouts activated in sequence on a site whose navigation was
`Home / Services / Work / Contact` throughout:

```datatable
columns: Layout | What it rendered instead | Site nav rendered
widths: 3.6cm | 7.6cm | X
bold: 1
tone: medium
---
`atelier` | Works, About, Explorer | No
`consultancy` | Meridian & Co, Services, Approach, Book a briefing | No
`lumen` | Lumen., Features, Voices, The essay | No
`kestrel` (hand-authored) | the site's own four items | Yes
---
```

`nav.conf` is the documented way to give a site its navigation and `[% nav %]`
is the documented way for a layout to render it. The navigation was written,
stored, readable back through the API, and never rendered.

Found while **building** a site rather than testing one, which is why a release
pass had not reached it: every page returns 200 and every tool returns `ok:1`.

# Why this is the engine's problem and not only the catalogue's

The catalogue is being fixed where it lives. That does not close this, for two
reasons.

**It is undiscoverable before commitment.** `list_layout_catalogue` returns 23
layouts with names, versions, themes and tags, and nothing distinguishes a
showcase from a layout usable for a site with its own pages. The only way to
find out is to install it, bind it to a domain, render a page and look at the
result - and looking at the result is a step an agent building a site has no
reason to insert after four consecutive `ok:1`s.

**The engine already knows.** `action_layout_activate` validates the layout
directory before it writes the pointer. At that moment the template is open and
the answer to "does this render the site's navigation" is one match away. The
information exists and is discarded.

That is the shape of SM283, SM296, SM306, SM311, SM313, SM315, SM317, SM322 and
SM329 - a control reporting success without doing, or without checking, the
work. Every one of those was found in the field rather than by a gate, and each
time the fix was to make the control state what it established.

# What to do

Say it at activation
: `action_layout_activate` returns `renders_nav` and `renders_content` for the
  layout it just bound. A layout that renders neither is still activated - that
  is the caller's choice to make and a showcase is a legitimate thing to
  activate - but the acknowledgement stops being indistinguishable from binding
  a working site layout. This is the smallest change and the one that turns a
  silent wrong choice into a visible one at the moment it is made.

Declare the kind, and surface it in the catalogue
: `layout.json` already carries `name`, `version`, `description`, `tags` and a
  `tokens` block, so it is the natural place for a `kind`. [[SM203]] set the
  precedent for declaring a layout's contract as data rather than as prose.
  This half needs the catalogue repository to move first.

Assert it rather than describing it
: a lint that renders each shipped layout with a two-item nav and a known body
  and asserts both appear would have caught all four cases above. Same class as
  `t/lint/45`, which exists so an ADR cannot name fields that do not exist.

# What it is worth, stated honestly

The first item is small, additive, and does not change what activation does -
only what it says about it. It would not have prevented the build failure, since
an agent that does not read the extra field is no better off. What it does is
make the failure **diagnosable in one call** instead of requiring a render and a
visual inspection, and it puts the fact in the transcript at the moment the
decision was made rather than an hour later.

The lint is the item that would actually have caught this before shipping, and
it is the one that depends on having layouts in the tree to render.

# Verification

- `activate_layout` reports whether the layout it bound renders the site's
  navigation and the page body.
- A layout that renders neither is still activated, and the response says so.
- Each shipped layout, given a two-item `nav.conf` and a Markdown body, renders
  both - or is marked as a showcase in its manifest.
- `list_layout_catalogue` lets a caller tell the two apart without installing.

# Related

[[SM203]] (declared token vocabulary in `layout.json` - the same
documentation-as-data shape), [[SM123]] (theme discovery and the asset-mirror
lifecycle), `lazysite-layouts/docs/BRINGING-THE-CATALOGUE-UP-TO-DATE.md` (the
catalogue half), and the worked example the report cites:
`lazysite-sites/edge.explore/mock-engagement/layout/kestrel/`, about thirty
lines of Template Toolkit that renders the site's own navigation on the first
try.
