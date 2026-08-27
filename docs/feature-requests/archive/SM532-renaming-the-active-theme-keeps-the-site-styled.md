---
title: "SM532: renaming the active theme keeps the site styled"
subtitle: "A rename of the active or in-use theme succeeds and leaves the site pointing at a theme that no longer exists."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): decided REFUSE. action_theme_rename now applies the two guards action_theme_delete applies, with the same wording - the active theme, and any theme a configured domain resolves to (named) - and checks the directory rename, reporting a failure as one; rename gains no conf-write path, and the operator activates another theme first exactly as before a delete. Proving test t/unit/manager/102-renaming-the-active-theme-keeps-the-site-styled.t pins both refusals, the untouched conf, directory and mirror, that a free theme still renames with its mirror, and that the two verbs word their refusals alike. FOUND 2026-08-25 by the themes structural review, PROVEN by probe tmp/tl-probe-rename-active.pl; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. action_theme_delete refuses the active theme (Manager/Themes.pm 1269) and any theme a domain uses (1280); action_theme_rename at 1359-1383 checks neither, returns ok:1 and leaves theme: t in lazysite.conf while themes/t is gone. The probe shows theme_list: active=t names=u active_flags=0, after which every page renders through the layout with no theme mirror. The rename at 1375 is also unchecked. Fix: the two guards from delete, plus repointing or refusing the active name."
---

# The finding

`action_theme_delete` refuses the active theme (`Manager/Themes.pm
1269`) and any theme a domain uses (`1280`); `action_theme_rename`
(`Manager/Themes.pm 1359-1383`) checks neither, returns `ok:1`, and
leaves `theme: t` in lazysite.conf while `themes/t` is gone: `theme_list:
active=t names=u active_flags=0`. Every page then renders through the
layout with no theme mirror. The `rename` at `1375` is also unchecked.

# Why it matters

Operability: one successful-looking call strands a live site unstyled, with
a reply that gives the operator no hint that anything needs repointing. The
delete path already knows how to refuse this; the rename path lacks the
same guard.

# The proving test

NEW `t/unit/manager/102-renaming-the-active-theme-keeps-the-site-styled.t`:
`is($ren->{ok}, 0)` or `is((_read_active_layout_and_theme())[1], 'u')` -
the SM decides which.

# Fix shape

Apply the two guards from `action_theme_delete` to rename, then either
repoint the active name (and any domain override) to the new name or
refuse the rename; this filing decides which when picked.
