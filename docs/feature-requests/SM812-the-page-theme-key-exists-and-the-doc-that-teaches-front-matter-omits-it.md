---
id: SM812
title: "SM812: the page theme key exists, and the doc that teaches front matter omits it"
subtitle: "The field reports that a page may override its layout but not its theme, and a shipped build hardcodes a stylesheet link to work around it - which silently disables that theme's own configuration block. The premise is wrong and the cost is real: a per-page `theme:` key shipped in SM120 and is documented in FEATURES.md, but not in /docs/frontmatter, which is the page a site author reads. The workaround was never necessary. Folder inheritance, the half that makes it usable across a section, genuinely does not exist."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-09
raised-by: sites agent
area: authoring
status-note: "PART BUILT 2026-09-09: the documentation half is fixed on claude/0-13-10-changelog - starter/docs/frontmatter.md now documents `theme` beside `layout`, which is the whole of what stood between the reporting build and the feature it worked around. The FOLDER INHERITANCE half is not built and is a real request: setting a theme per page across a section is the same per-page discipline that already goes wrong with auth: and search:. The two design questions the filing raises - cache invalidation when an inherited theme changes, and page-over-folder-over-domain precedence - belong to that half."
---

# The correction first

> There is **no `theme` key**. Searched the whole document: zero occurrences.

The document is right and the conclusion drawn from it is not. `lazysite-processor.pl:7083`:

    # SM120: a page may pin a theme via front matter (theme:), sanitised the
    # same way as layout:; falls back to the active/site theme.
    my $page_theme = ( defined $meta->{theme} && $meta->{theme} =~ /^[A-Za-z0-9_-]+$/ )
        ? $meta->{theme} : $vars->{theme};

`docs/FEATURES.md` line 98 lists it: `` `layout`, `theme` | Per-page
layout/theme override ``. And SM275 already corrected a comment that described
this pin as preview-only, in words worth repeating here because they apply
exactly:

> A wrong-but-plausible statement costs more than an absent one: a reader
> trusting it would not reach for the pin on a page they meant to keep.

`starter/docs/frontmatter.md` documented nine references to `layout` and, for
`theme`, one incidental mention in unrelated prose. So the feature has existed
since SM120, and the page a site author reads to learn front matter does not
mention it.

# What the gap cost, which is the part that matters

The report is valuable precisely because it shows the cost. On
`sovereigncomputing.org` the intranet layout links its stylesheet directly, with
a comment explaining that `theme_assets` would otherwise resolve the public
theme. That reasoning is sound given what its author could find. Its
consequences, which the author did not choose:

- **The theme's configuration is inert.** `theme.json` declares a
  `config.colours` block naming band, accent, ink, ground and rule - the
  operator-settable retint that makes a theme reusable - while `main.css` sets
  those tokens as literals and is served statically. Nothing reads the config.
  The theme looks configurable and is not.
- **Theme varieties are impossible.** One hardcoded path is one theme, so a
  layout cannot offer a default, a high-contrast and a dark treatment.

Neither was necessary. `theme: intranet` in that section's front matter does
what the hardcoded link does, through `theme_assets`, with the configuration
block live and varieties selectable.

**This is the shape this project keeps filing against, arriving from the other
side.** Usually it is a declaration the code ignores; here it is code the
documentation ignores, and the result is the same - somebody built a workaround
for a feature that was already there, and the workaround took two capabilities
away without saying so.

# What is asked

1. **Document `theme` beside `layout` in `/docs/frontmatter`.** BUILT. It says
   what it overrides, that it is sanitised like `layout`, and that a theme the
   layout does not support renders as no theme rather than breaking the page.
2. **Folder inheritance: not built, and the real request.** A theme set on a
   folder's index applying to everything beneath it. The reporter's argument for
   it stands on its own: per-page discipline across a whole section is the same
   burden that already goes wrong with `auth:` and `search:`, and one missed
   page is a page dressed in the public theme.
3. **Two design questions belong with item 2**, both from the filing:
   - **Cache keying.** Each page caches as its own `.html`, so the resolved
     stylesheet is baked into that page's cache. What invalidates a section when
     its inherited theme changes? A nav change does not retro-invalidate cached
     pages today, and a theme change should not repeat that.
   - **Precedence.** Page over folder over domain matches `layout` and should be
     stated rather than inferred - the surprising case, a page that sets a
     layout but not a theme, is exactly the one that produced the workaround.

# What should be told to the reporting build

That the workaround can be removed: `theme:` in front matter, and the
configuration block and theme varieties both come back. That is a site change,
not an engine one, and it is worth doing before the intranet work builds further
on the hardcoded link.

# Provenance

`inbox/2026-09-09-a-page-can-choose-its-layout-but-not-its-theme.md`. The
premise was checked against `lazysite-processor.pl:7083`, `docs/FEATURES.md:98`
and `starter/docs/frontmatter.md` before this was written; the cost described in
the report was accepted as reported.

# THE ADVICE IN THIS FILING IS RETRACTED, 2026-09-10

Item 2 of "What should be told to the reporting build" said the hardcoded
stylesheet link could come out, replaced by `theme_assets` plus a per-page
`theme:`. **That would have broken the site**, and it was filed to the sites
agent as something to do.

[[SM820]] is why: the per-page override resolves to
`/lazysite-assets/<layout>/<theme>/`, which is written **at activation**. That
site's intranet theme is by definition never the activated one - which is the
whole reason the link was hardcoded - so the replacement links two 404s and
renders the intranet completely unstyled. Measured on edge: background
`rgba(0,0,0,0)`, font Times New Roman.

**The sites agent tested it instead of doing it, and reported back.** Nothing
broke, and the order they worked in is the reason. The retraction is in the reply
of 2026-09-10.

What survives from this filing: the key exists, it has since SM120, and
`/docs/frontmatter` now documents it - which was the real defect and is fixed and
shipped in 0.13.10. What does not survive: any suggestion that a site can drop a
hardcoded link today. It cannot, until SM820 is built.

**And the lesson is mine rather than theirs.** The filing verified that the key
existed and stopped there. It did not verify that the key WORKS for the case it
was being recommended for - a theme that is not the activated one, which is the
only case that site has. Establishing that a feature exists is not establishing
that it serves the use it is being recommended for.
