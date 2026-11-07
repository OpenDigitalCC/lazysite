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
      assets/             <- everything a browser fetches
        main.css          <- the theme's stylesheet
        logo.svg
        fonts/...

    public_html/lazysite-assets/default/odcc/
      main.css            <- web-served copy of assets/ (placed on install)
      logo.svg
      fonts/...

Only `assets/` is copied to `lazysite-assets/`: a stylesheet beside
`theme.json` is never served, and a theme whose CSS is all outside
`assets/` renders unstyled.

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

### Forms under a theme

A page carrying a form (a `::: form` block, or the sign-in, reset and
set-password pages) links `/assets/lazysite-chrome.css`, first in the
head. It gives the form a usable base: spacing between fields, full-width
inputs, buttons in the page's font, the step fieldsets of a stepped form
and a marked error line. Every one of those rules is inside `:where()`,
so it has zero specificity, and it sets no colour beyond `currentColor`
and `inherit`. Any rule your theme writes about the same element wins,
even a bare `button { ... }`, so a theme that styles forms needs no
override and one that does not still gets readable forms.

### theme_assets TT variable

`[% theme_assets %]` resolves to `/lazysite-assets/LAYOUT/THEME/`
when a compatible theme is active, pointing at the web-served
assets dir. Nothing when no theme is active.

### Installing a theme

**Via the manager UI.** On `/manager/appearance`, click "Browse
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

Every entry is checked before any is extracted: an absolute path, a
`..`, a symbolic link or a file type the web server runs (`.php`,
`.cgi`, `.pl` and the rest) refuses the whole archive, and so does an
archive over the site's upload limit (`manager_upload_max_mb`). A theme
whose name is already installed is installed beside it under a dated
name (`YYYYMMDD-name`), never over it. Nothing is activated. A theme
with stylesheets outside `assets/` and none inside it is installed with
a warning in `warnings` naming each file and where it belongs
(`assets/main.css` for a `main.css` at the root); every install says so,
the layout installs in `theme_warnings`.

**Over MCP.** `install_theme` takes the same zip, base64-encoded, and
installs it through the same code with the same checks - so a theme's
fonts and images travel with its stylesheet in one call. It needs
`manage_themes`. Preview the result with `preview_page` and `theme`,
then `activate_theme`.

A theme declaring `layouts: ["default", "landing"]` ends up
with files duplicated under both layouts. That's the trade-off
for per-layout scoping; the manager doesn't symlink or share.

### Activating a theme

Edit `lazysite.conf`:

    theme: odcc

Or click **Activate** next to a theme on the manager Appearance page
(`/manager/appearance`), which sets it site-wide and clears the page cache.

### Previewing a theme

Before activating a theme for all visitors, a manager can preview it for
their own session only. On the manager Appearance page, click **Preview**
next to any non-active theme - including themes built for a layout that
is not currently active. The site opens in a new tab rendered against
the previewed layout and theme; other visitors keep seeing the active
theme.

Preview is driven by a short-lived, signed `lzs_preview` cookie scoped
to the previewing browser. Previewed pages are never cached and never
served from cache, so a preview cannot leak into what anonymous visitors
see. Click **Stop preview** to end it; the cookie also expires on its
own after an hour.

**One page, from an agent.** MCP `preview_page` takes `theme`: the page
(or a draft passed as `content`) is rendered with that installed theme
in place of the site's, the section's and the page's own, and the HTML
comes back in the result. Nothing is activated, cached or written. It
needs `manage_themes` or `manage_layouts` as well as `manage_content`,
and a theme that is not installed for the layout the page renders with
is refused, naming the layout. The manager's page preview (the
`preview` action) takes the same `theme` parameter.

### Theme name sanitisation

Theme names are sanitised to `[A-Za-z0-9_-]` at both install and
resolve time. Anything else is stripped. A name that sanitises
to empty falls back to no theme.

### Related

- [Layouts](/docs/features/configuration/layouts)
- [Remote layouts](/docs/features/configuration/remote-layouts)
  (flat asset path — D013 separation does not apply)
- [theme.json reference](/docs/features/configuration/theme-json)
