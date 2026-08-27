---
title: "SM241 - Binding a theme to a domain does not publish its assets"
subtitle: "domain-set writes the binding and no mirror, so a secondary domain serves a 404 stylesheet. The layout renders its chrome correctly and the page looks chrome-less because nothing styles it."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.2 edge line (2026-08-08, commit 9a0adf2). Reported by the sjm-claude-code site agent 2026-08-08, diagnosed on harmony2050.org (a secondary domain on the theunited.fund instance, 0.10.0). Verified: the mirror is written by theme-activate, layout-activate/layout-install, create_theme with activate:true, and site_apply - and by no path in Domains.pm. The documented remedy is worse than useless here, which is SM242."
---

# SM241 - domain-set does not mirror theme assets

## Why

harmony2050.org served an unstyled page. The operator had selected the layout and
theme and reported "no chrome". The layout was in fact applied and rendering its
header, nav and footer correctly - but `/lazysite-assets/harmony/harmony/main.css`
returned **404**, so nothing was styled and the chrome was invisible.

`domains-list` showed the domain correctly registered: content root
`sites/harmony2050.org`, layout `harmony`, theme `harmony`. The theme source was
correctly placed at `lazysite/layouts/harmony/themes/harmony/assets/main.css`.
Only the public mirror was missing.

A theme with no mirror is not servable by anything. Binding one to a domain and
producing an unstyled site is the platform accepting an instruction and not
carrying it out.

## What is true today

`_mirror_theme_assets` is called from exactly four places:

| Path | Call |
|---|---|
| `Themes.pm` `action_theme_activate` | `_mirror_theme_assets( $active_layout, $theme_name )` |
| `Themes.pm` (theme upload/install) | `_mirror_theme_assets( $layout_name, ... )` |
| `Layouts.pm` (layout activate / install) | `_mirror_theme_assets( $layout, $tname )` |
| `SitePackage.pm` (SM193, mirror on apply) | `_mirror_theme_assets( $layout, $theme )` |

`Domains.pm` contains none. So binding a layout and theme to a domain - the
natural "activation" for a secondary domain, and the only thing the operator or
an agent would think to do - writes the binding and publishes nothing.

**For a secondary domain, `site_apply` is the only correct route today**, and no
document says so. That is SM242.

### One correction to the report

The reporting agent believed `theme-activate` would mirror under the *active*
layout and so write the wrong path. It is narrower than that: `action_theme_activate`
resolves `$themes_dir` as `layouts/$active_layout/themes` and returns **"Theme
not found"** when the theme is not there. So activating a theme belonging to a
different layout does not mirror wrongly - it refuses outright.

The agent's substantive point is unaffected and arguably stronger: the documented
remedy ("re-activate to rebuild it") cannot fix a secondary domain, either
because it refuses, or - when the layouts happen to match - because it rewrites
the instance-wide `theme:` key and switches the primary site's theme. Here that
would have moved theunited.fund from `united-r6` to `harmony`.

## What to change

**Have `domain_set` mirror the layout/theme it binds.** When a `domain-set` call
changes `layout` or `theme` for a host, mirror that pair's assets. It makes the
natural action the correct one and removes the trap rather than documenting it.

Two details that matter:

- Mirror the **theme's own layout**, not the active one. The whole failure here
  is a secondary domain whose layout differs from the primary's.
- The mirror is a **copy**, so it does not track later edits to the theme source.
  That is already true of every other mirroring path and is not made worse here,
  but it is why a hand-copied fallback (what the agent did to restore the site)
  should be replaced by a real mirroring call when one exists.

**Consider mirroring on `create_theme` regardless of `activate`.** A theme with
no mirror is not servable, so writing one without mirroring produces an artifact
that validates and cannot be used. This is a smaller, independent improvement and
would have limited the blast radius here.

## Verification

- Binding a layout+theme to a secondary domain via `domain-set` publishes
  `/lazysite-assets/<layout>/<theme>/` and the domain serves styled.
- The mirror is written under the theme's own layout, including when it differs
  from the instance-wide active layout.
- The primary site's `theme:` and `layout:` keys are untouched by a `domain-set`
  on another host - the bug this fix must not reintroduce.
- A `domain-set` that changes neither layout nor theme does no mirroring work.

## Not in scope

- Making the mirror track theme-source edits. It is a copy by design, everywhere.
- Any change to `theme-activate`'s instance-wide semantics. That is what
  SM238 addresses by giving the operation a `host`.
