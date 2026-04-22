---
title: Themes
subtitle: Design tokens and assets for a layout. Install multiple, activate one.
tags:
  - configuration
  - template
---

## Themes

A theme supplies colours, fonts, spacing, and assets on top of a
[layout](/docs/features/configuration/layouts). Themes are
layout-specific: a theme declares which layouts it's compatible
with and is installed once under each.

### Setting a theme

In `lazysite.conf`:

    layout: default
    theme: odcc

Both keys are required. The theme is loaded from
`lazysite/layouts/default/themes/odcc/`. If the theme's own
compatibility list doesn't include `default`, the theme is
ignored and the page renders with layout chrome only (no theme
styling).

### On-disk structure

A theme has two parts, stored in separate locations:

    public_html/lazysite/layouts/default/themes/odcc/
      theme.json          <- manifest (required)
      main.css            <- layout-scoped stylesheet
      assets/             <- fonts, images, etc. (optional)

    public_html/lazysite-assets/default/odcc/
      main.css            <- web-served copy (auto-placed on install)
      logo.svg
      fonts/...

The split is deliberate: `lazysite/` is blocked from direct web
access (`<Location /lazysite/>` denies all in the Hestia
template); `lazysite-assets/` is served as normal static content.

### theme.json

    {
      "name": "odcc",
      "version": "1.0.0",
      "description": "OpenDigitalCC brand theme",
      "author": "OpenDigitalCC",
      "layouts": ["default"],
      "config": {
        "colours": {
          "primary": "#332b82",
          "text": "#2a2a2a",
          "accent": "#ff6b35"
        },
        "fonts": {
          "body": "Open Sans",
          "heading": "Source Sans 3"
        },
        "spacing": { "unit": "8px" }
      },
      "files": [
        "theme.json",
        "main.css",
        "assets/logo.svg"
      ]
    }

**Required fields:** `name`, `version`, `description`, `author`,
`layouts` (array), `config` (object).

- `layouts` lists the layout names this theme is compatible with.
  The manager installs the theme under each; the processor refuses
  to apply it to any layout not in this list.
- `config` groups design tokens. Each group is a flat object of
  string values. Group and key names are author-chosen but must
  match `^[A-Za-z0-9_-]+$` to survive CSS variable naming.

### Auto-generated CSS variables

The processor exposes `[% theme_css %]` in layout.tt: a `<style>`
block of `:root` CSS custom properties derived from `theme.config`:

    <style>
    :root {
      --theme-colours-primary: #332b82;
      --theme-colours-text: #2a2a2a;
      --theme-colours-accent: #ff6b35;
      --theme-fonts-body: Open Sans;
      --theme-fonts-heading: Source Sans 3;
      --theme-spacing-unit: 8px;
    }
    </style>

Naming convention: `--theme-GROUP-KEY`. Values are written
verbatim with `;{}<>` stripped to prevent declaration escape.

Use in a layout:

    <head>
    [% theme_css %]
    <link rel="stylesheet" href="[% theme_assets %]/main.css">
    </head>

...and in the theme's CSS:

    body {
      color: var(--theme-colours-text);
      background: var(--theme-colours-background);
      font-family: var(--theme-fonts-body);
    }

The advantage over hardcoded values: a single theme fork copy
can tweak just the colours while reusing the layout's structure
and the theme's base stylesheet.

### theme_assets TT variable

`[% theme_assets %]` resolves to `/lazysite-assets/LAYOUT/THEME/`
when a compatible theme is active, pointing at the web-served
assets dir. Nothing when no theme is active.

### Installing a theme

**Via the manager UI.** On `/manager/themes`, click "Browse
releases" to list published releases of the `layouts_repo`
(configured in `lazysite.conf`). Install pulls every valid theme
in a release in one operation.

**Manually.** Upload a zip containing `theme.json` at the root
via the Upload Theme card. The manager:

1. Validates `theme.json`, including that `layouts[]` is present
   and non-empty.
2. Verifies every layout listed in `layouts[]` is installed at
   `lazysite/layouts/NAME/layout.tt`.
3. Installs a copy of the theme under each layout in the list,
   with assets mirrored to `/lazysite-assets/LAYOUT/THEME/` for
   each.

A theme declaring `layouts: ["default", "landing"]` ends up
with files duplicated under both layouts. That's the trade-off
for per-layout scoping; the manager doesn't symlink or share.

### Activating a theme

Edit `lazysite.conf`:

    theme: odcc

Or use the quick switcher in the admin bar (visible to managers
only, when more than one compatible theme is installed).

### Theme name sanitisation

Theme names are sanitised to `[A-Za-z0-9_-]` at both install and
resolve time. Anything else is stripped. A name that sanitises
to empty falls back to no theme.

### Related

- [Layouts](/docs/features/configuration/layouts)
- [Remote layouts](/docs/features/configuration/remote-layouts)
  (flat asset path — D013 separation does not apply)
- [theme.json reference](/docs/features/configuration/theme-json)
