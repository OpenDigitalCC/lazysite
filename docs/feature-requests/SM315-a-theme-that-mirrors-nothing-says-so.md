---
title: "SM315 - a theme whose assets are one directory out serves an unstyled site"
subtitle: "The upload succeeds, activate_layout returns ok:1, the mirror is empty, and every page returns 200 with no stylesheet. Only a screenshot found it."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.10. _mirror_theme_assets returns { mirrored, dest, expected, reason, misplaced }; activation reports assets_mirrored and warns on zero; lazysite check carries report_theme_assets_mirrored as the standing version, for a site already in that state. The count is taken by walking the DESTINATION after the copy, not by counting what was attempted. A misplaced asset is named specifically, because 'no assets' and 'a stylesheet in the wrong directory' need different sentences and only the second is a site about to render unstyled. VERIFIED by t/unit/manager/77, shown to fail before the fix. FILED 2026-08-15 from a site-agent report measured on edge/0.10.9 while authoring a layout for a site build."
---

# What was found

Theme assets live at `layouts/<layout>/themes/<theme>/assets/` and are mirrored
to `/lazysite-assets/<layout>/<theme>/` on activation. Put them one level higher
- beside `theme.json`, which is where an author who has not dissected a working
layout will naturally put them - and every signal says it worked:

- the upload succeeds
- `activate_layout` returns `ok:1`
- the mirror is created empty, or not at all
- `theme_assets` resolves to nothing, so the stylesheet link is never emitted
- every page returns **200**, valid, fast and completely unstyled

The diagnosis took a screenshot. At the HTTP level a fully unstyled site is
indistinguishable from a working one, and an agent building over MCP and WebDAV
has no screenshot step - it would hand over an unstyled site reporting success.

# The fix

The tool already knew. `_mirror_theme_assets` ran at activation and could count
what it copied; it returned nothing and said nothing. Zero assets for a theme
that declares colours and fonts is almost always a mistake, and the
acknowledgement the caller is already reading is the one place that can say so.

**The count is of what is there**, taken by walking the destination afterwards. A
count of intentions is precisely the class of defect this filing exists to close.

**A misplaced asset is named.** "No assets" describes a theme that has none; a
`.css` beside `theme.json` describes a theme whose author believed they had
provided one. Telling the second group the first sentence leaves them looking at
a stylesheet they just uploaded while being told none exists.

The standing check in `lazysite check` earns its place separately: the activation
warning cannot help a site that reached this state another way - a partial
deploy, a mirror cleared by hand, an asset directory that vanished - and those
are sites rendering unstyled right now with nothing reporting it.

# Related

SM123 (theme discovery and the asset-mirror lifecycle), SM203 (the layout
contract as declared data), and SM309, which is the same shape applied to
front-door mode.
