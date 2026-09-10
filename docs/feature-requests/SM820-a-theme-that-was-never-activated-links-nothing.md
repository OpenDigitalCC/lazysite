---
id: SM820
title: "SM820: a per-page theme that was never activated links stylesheets that do not exist"
subtitle: "1310E-08 step 4. The per-page `theme:` key works, and it resolves to `/lazysite-assets/<layout>/<theme>/`, which is written AT ACTIVATION. A theme present in the tree but never activated has no mirror, so the page links two 404s and renders completely unstyled - measured: background rgba(0,0,0,0), font Times New Roman. This invalidates the advice SM812 sent to a live site, which would have made it worse. An unknown theme name falls back safely; a real but unmirrored one fails silently to nothing."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-10
raised-by: sites agent
area: themes
status-note: "RULED 2026-09-10 and NOT BUILT: the per-page theme override resolves to the theme SOURCE rather than the activation mirror, plus a fallback - an unmirrored theme falls back to the activated one exactly as an unknown name already does. Needs care against SM795 engine-tree exclusion, since a web-reachable theme source is precisely what that exclusion was written about. Until it ships, a site cannot replace a hardcoded stylesheet link with a per-page theme: - SM812 advice to do so is retracted, and the reporting build was told not to."
---

# What was measured

A page carrying `theme: lumen-backup-20260818T211110Z` - a real theme in the
tree, never activated - links two stylesheets and **both 404**:

    /lazysite-assets/lumen/lumen/theme-tokens.css                200
    /lazysite-assets/lumen/lumen/main.css                        200
    /lazysite-assets/lumen/lumen-backup-.../theme-tokens.css     404
    /lazysite-assets/lumen/lumen-backup-.../main.css             404

And the consequence is not degradation, it is total:

    default page      background rgb(251,247,239)   font Inter
    overridden page   background rgba(0,0,0,0)      font "Times New Roman"

The cause is that the mirror under `/lazysite-assets/<layout>/<theme>/` is
written **at activation**. The per-page override resolves to the mirror, so a
theme that has never been the activated one has nothing behind its URL.

# The asymmetry, which is the sharpest part of the report

- `theme: no-such-theme-at-all` - **falls back safely** to the domain's
  activated theme. Verified in step 3.
- `theme: a-real-theme-never-activated` - **fails silently to no styling at
  all.**

**The safer outcome is given to the more obviously wrong input.** A typo is
handled gracefully; a name that is correct in every respect except that nobody
ever activated it produces an unstyled page and no error anywhere.

# It invalidates advice already sent to a live site

[[SM812]] concluded that `sovereigncomputing.org` could remove its hardcoded
stylesheet link and use `theme_assets` plus a per-page `theme:`, and that was
filed to the sites agent as something to do on a copy first. **It would not have
worked.** That site's intranet theme is by definition never the activated one -
that is the whole reason the link was hardcoded - so the replacement would have
produced unstyled intranet pages. Worse than what it replaced.

The reporter did not act on it, tested it instead, and said so. That is the
right order and it is why nothing broke. **The advice is retracted in the reply
of 2026-09-10**, and SM812's first half stands only as a documentation fix: the
key exists and is now documented. The workaround cannot come out until this is
fixed.

# The two candidate fixes, both the release manager's to choose

1. **Mirror a theme's assets when it is REFERENCED, not only when activated.**
   The mirror stays the serving path, and a page naming a theme causes its assets
   to exist. Cost: a render-time side effect that writes files, on a path that is
   otherwise read-only, and a question about who owns the write when the
   referencing page is rendered by a visitor rather than an operator.
2. **Resolve the per-page override to the theme SOURCE rather than the mirror.**
   No write, no timing question. Cost: two serving paths for the same asset, and
   the source tree becomes web-reachable for themes in a way it is not today -
   which touches the exclusion [[SM795]] established, so it needs care rather
   than a flag.

**A third thing is needed whichever is chosen:** the failure must stop being
silent. A per-page theme that resolves to no mirror should either fall back to
the activated theme, exactly as an unknown name does, or refuse the render with a
named reason. Producing a page that links two 404s and says nothing is the state
that let this reach a measurement rather than a log line.

Recommendation: **2, plus the fallback.** It has no write and no timing problem,
and the fallback removes the asymmetry the reporter identified regardless of which
resolution path is taken. Option 1's render-time write is the kind of side effect
that becomes a security question later.

# The same suspicion, elsewhere in the same test run

[[SM819]] found `.mg-row-actions` computing `margin-left: 0` on a build whose
stylesheet demonstrably contains `margin-left: auto`, which is consistent with a
served asset that an upgrade did not refresh. **Two findings in one run pointing
at mirrored assets being stale or absent** suggests the question is broader than
themes: what refreshes `/lazysite-assets/` and `/manager/assets/`, and when?
Worth answering once for both rather than twice separately.

# Provenance

`inbox/2026-09-10-1310E-results-0.13.10.md`, ref 1310E-08 step 4. The 404s, the
computed background and font, and the three-step progression that isolated it are
the reporter's.

# RULED 2026-09-10, and one paragraph of this filing was wrong

**Ruled: resolve the per-page override to the theme SOURCE, plus the fallback.**
No render-time write and no timing question; option 1's write from a render path
is the kind of side effect that becomes a security question later. The fallback
is part of the ruling rather than an extra: an unmirrored theme falls back to the
activated one exactly as an unknown name already does, which removes the
asymmetry the reporter identified. Care is needed against [[SM795]]'s engine-tree
exclusion - the theme source becoming web-reachable is precisely what that
exclusion was written about, so this is a narrow, named exception or it is not
done at all.

**The "two findings point at stale mirrors" paragraph is withdrawn.** [[SM819]]'s
computed `margin-left: 0` turned out to be `auto` resolving to zero in a grid
area with no free space - the stylesheet was correct and being served. So there
is one mirror finding here, not two, and the pairing was mine. The 404s measured
in this filing are unaffected: they were measured, and they stand.

NOT YET BUILT. The site's hardcoded stylesheet link cannot come out until it is.

# ATTEMPTED 2026-09-10 AND REVERTED - the fallback could not be shown to work

The fallback half was built and then taken out again, because it could not be
demonstrated to change anything. Recording the attempt in full, because the next
person should start from here rather than repeat it.

## What was built

In `lazysite-processor.pl`, immediately after `resolve_theme` returns: if the
theme is `is_active` but `-d "$DOCROOT/lazysite-assets/<layout>/<theme>"` is
false, log a WARN and downgrade `$info` to `{}` so the page takes the existing
else-branch fallback - which already resolves `theme_assets` to the layout's
`default_theme` mirror. That reuses the engine's own pattern: the else branch
performs the identical `-d` check on the same path shape.

## Why it was reverted

**A/B with the file state verified at each step produced identical output.** With
the guard present and with it replaced by `unless (0)`, a page carrying
`theme: unmirrored` resolved `theme_assets` to `/lazysite-assets/base/plain` -
the default-theme mirror - both times.

That is unexplained, and the pieces contradict each other:

- A diagnostic written to a file (stderr is swallowed by `TestHelper`'s
  `load_processor`) shows `resolve_theme` IS called with `theme=unmirrored` and
  finds its `theme.json`: `resolve layout=base theme=unmirrored json=1`.
- `resolve_theme` has exactly **one** call site, so nothing else is overwriting
  the result afterwards.
- The theme declares `layouts: ["base"]` and the layout is `base`, so the
  compatibility check should pass and `is_active` should be 1.
- With `is_active` 1 and the guard disabled, `theme_assets` should have been
  `/lazysite-assets/base/unmirrored`. It was not.

So either the engine already falls back somewhere this reading has not found -
making the change redundant - or the fixture does not reach the case despite
appearing to. **Either way the change is unverifiable, and a test that passes
whether the fix is present or absent is not a test.** Shipping it would be the
thing this filing's own neighbours were reverted for.

## What the next attempt should do differently

1. **Reproduce it against a real docroot before writing any code.** The field
   measured this on edge with a backup theme; a unit fixture asserting on
   `theme_assets` did not reproduce it, and finding out why is the first task,
   not the last.
2. **Consider the third option neither of us offered.** `_mirror_theme_assets`
   (`lib/Lazysite/Manager/Themes.pm:937`) is idempotent, per-theme, and already
   called from activation, layout install and package apply. **Mirroring every
   theme a layout carries, rather than only the activated one, sidesteps the
   resolution path entirely** - no render-time write, no serving change, and no
   [[SM795]] carve-out for a web-reachable theme source. It is also testable
   where the work happens, at the mirroring function, rather than through a
   render. That is very likely a better answer than the one ruled, and the
   ruling was made without it because it was not offered.
3. If the source-resolution route is still wanted, the SM795 exclusion is the
   hard part and deserves its own security review rather than a flag.
