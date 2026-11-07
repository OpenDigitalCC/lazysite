---
id: SM1386
title: "SM1386: a theme install warns when its stylesheets are outside assets/"
subtitle: "Only a theme's assets/ is served, so a zip with main.css beside theme.json installed and previewed with no CSS and nothing said why. Every install door now installs it with a warning naming each stylesheet and where it belongs."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent (0.16.7 small fixes)"
area: themes
status-note: "SHIPPED (0.16.7) on n764: Themes::_css_outside_assets_warning, asked by _install_theme_from_dir, the one install path every door uses; warnings / theme_warnings in the answer; the manager shows it. t/unit/manager/472."
---

# What happened

`install_theme` (MCP) accepted a zip with `main.css` at its root beside
`theme.json`. The mirror to `/lazysite-assets/<layout>/<theme>/`, which is what
a theme's pages link, copies the theme's `assets/` and nothing else, so the
theme installed, previewed and activated with no CSS. The answer was `ok` and
said nothing. The themes doc's own on-disk picture put `main.css` beside
`theme.json`, which is where the author had put it.

# What shipped

**A warning, never a refusal.** `Themes::_install_theme_from_dir`, which every
install door calls, looks for `.css` files in the theme. When there is one outside
`assets/` and none inside it, the theme is installed and the answer carries
`warnings`: the theme's name, each stylesheet with where it belongs
(`main.css (belongs at assets/main.css)`), that only `assets/` is served, and to
move them and install again. The event log gets a WARN line. A theme with CSS in
`assets/` (another elsewhere is a source, not a mistake) and a theme with no CSS
(styled by its layout) are not warned about.

**Every door.**

- Control API `theme-upload` and the manager's Upload Theme, which shows the
  warning in its status line.
- MCP `install_theme`, whose description now says to put `main.css` in `assets/`.
- `layouts-install` (each theme's result carries its own `warnings`) and
  `layout-install` / MCP `install_layout` (`theme_warnings`, shown by the
  manager's catalogue install).

**Docs.** The themes page's on-disk picture shows `main.css` in `assets/`, says
only `assets/` is served, and names the warning.

# Tests

t/unit/manager/472: `theme-upload` over the control API with `main.css` at the
root installs and warns, naming the file and `assets/main.css`; MCP
`install_theme` names every stylesheet, nested ones included; a theme with CSS in
`assets/`, with CSS in both places, and with none is not warned about;
`_install_theme_from_dir` called as the layout installs call it warns. With
Themes.pm as on main there is no warning on any door.
