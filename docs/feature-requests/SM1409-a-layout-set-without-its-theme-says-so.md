---
id: SM1409
title: "SM1409: a layout set without a theme of its own says so in words"
subtitle: "domain-set of the layout alone kept the domain's theme from the other layout, mirrored the mixed pair and warned that assets belong under a path naming the new layout and the old theme. The set stays accepted; the mixed pair is not mirrored, and the warning names the theme that is not the layout's and what to send."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent, from edge testing of 0.16.7 (T-106, brief n774)"
area: domains
status-note: "SHIPPED (0.16.8) on n774: Domains::domain_set skips the mirror on a pair whose theme is not the layout's and says so (_foreign_theme_warning); domain_set's MCP description says it. t/unit/manager/481."
---

# What happened

On the 0.16.7 edge run (T-106, R9 W5) `domain-set` of a domain's layout alone,
with its theme still the other layout's, answered ok with the warning "no theme
assets were mirrored for this domain: the theme declares no assets/ directory.
Assets belong in .../layouts/kestrel/themes/lumen/assets". After a layout or
theme set, `domain_set` mirrors the pair the host resolves to
(`_effective_presentation`, SM241) and reports the result (SM322) through
`Themes::_mirror_warning`, which prints the path the mirror expected. For a
mixed pair that path names the new layout and the old theme, a directory nobody
made, and the advice ("assets belong in") is about a theme that has no
assets/ when the real fault is a theme that is not the layout's at all.

# Refuse, or say so

The brief offered both. The set stays accepted, because refusing it breaks two
documented paths: `domain_set`'s own description says to bind both by calling
twice, layout first, and `activate_layout` / `layout-activate` with a host send
the layout and then the theme as two `domain_set` calls. Refusing the first of
them would refuse those as well, and a domain whose layout and theme both
change has no single `domain_set` that does it.

So the answer says it in words. When the effective theme has no directory
under the effective layout's `themes/`, `domain_set` does not run the mirror on
the pair, returns `assets_mirrored: 0` and one warning:

- "no theme assets were mirrored for this domain: its theme 'lumen' is not a
  theme of layout 'kestrel' (its themes: ...). Send the layout and one of its
  themes together - layout-activate, or activate_layout over MCP, with host,
  layout and theme - or set this domain's theme to one of them next. Until then
  this domain will render with no stylesheet, and every page will still return
  200."
- For a layout that is not installed at all: "layout 'NAME' is not installed on
  this site", with the same consequence.

Neither names a path built from the two names. A theme set alone that is not
the layout's answers the same. A pair whose theme is the layout's mirrors and
reports as before (SM241, SM322), so the second call of the two-call binding
answers with no warning. `activate_layout` with host, layout and theme returns
the theme call's answer, so it shows no warning for the intermediate state.

MCP's `domain_set` description says the layout call warns until the theme is
set, and names `activate_layout` with host, layout and theme.

# Tests

t/unit/manager/481-a-layout-set-without-its-theme-says-so.t: a layout set
alone with the other layout's theme is accepted, warns naming the theme, the
layout, the layout's themes and what to send, never the mixed path nor "Assets
belong in", mirrors nothing and makes no mixed mirror directory; the theme set
next mirrors with no warning; a theme set alone that is not the layout's says
the same; a layout that is not installed is named as that; a layout that
carries the domain's theme mirrors as before. With the change reverted
subtests 1 to 3 fail. t/unit/manager/51 and 77 pass unchanged.
