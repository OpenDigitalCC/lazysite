---
title: Layouts and Themes
subtitle: How lazysite wraps page content in HTML layouts.
register:
  - sitemap.xml
  - llms.txt
---

## Layouts and themes

Every page on a lazysite site is rendered through a *layout*.
The processor converts the page's Markdown to HTML, then passes
it to the layout as the `[% content %]` variable. The layout
provides the surrounding HTML structure: `<head>`, navigation,
header, footer, main container, script tags, footer. A *theme*
sits on top of a layout and supplies colours, fonts, spacing,
and assets.

layout
: The `layout.tt` Template Toolkit file plus optional
  `layout.json`. Defines the full HTML chrome around every page.
  Installed at `lazysite/layouts/NAME/`.

theme
: Design tokens and assets compatible with one or more layouts.
  Installed nested at `lazysite/layouts/LAYOUT/themes/THEME/`.
  Web-accessible assets mirror to `/lazysite-assets/LAYOUT/THEME/`.

## The built-in fallback

lazysite includes a minimal layout embedded in the processor. It
activates when no layout is configured or the named layout isn't
installed. The fallback is functional but plain - content,
navigation, search, auth state, and an edit button when
permitted.

The fallback footer notes it's active:
`no layout.tt found, using built-in fallback`.

If the fallback appears unexpectedly, check:

- `layout:` is set in `lazysite.conf`
- `lazysite/layouts/NAME/layout.tt` exists and parses
- The Apache error log or dev-server output for Template
  Toolkit errors

## How the processor resolves a layout

1. `layout:` in the page's front matter (per-page override)
2. `layout:` in `lazysite.conf` (site-wide default)
3. Embedded fallback

For a named layout, the processor checks
`lazysite/layouts/NAME/layout.tt`.

A remote URL in `layout:` is fetched and cached; see
[remote layouts](/docs/features/configuration/remote-layouts).

## How the processor resolves a theme

1. `theme:` in `lazysite.conf`
2. The theme's `theme.json` at
   `lazysite/layouts/LAYOUT/themes/THEME/theme.json` is parsed
3. `theme.json.layouts[]` must contain the active layout; if
   it doesn't, the theme is ignored (no styling) and the page
   renders layout-only

## Example `lazysite.conf`

    site_name: My Site
    layout: default
    theme: odcc

## Single-page override

    ---
    title: Landing Page
    layout: campaign
    ---

## Installing a theme

### Via the manager

On `/manager/themes`, click "Browse releases" to list published
releases of the configured `layouts_repo`. Each release zipball
may carry multiple themes; each installs once per layout it
declares compatibility with.

### Manually

Create the nested directory and drop files:

    mkdir -p public_html/lazysite/layouts/default/themes/odcc
    cp -r mytheme/. public_html/lazysite/layouts/default/themes/odcc/

    mkdir -p public_html/lazysite-assets/default/odcc
    cp -r mytheme/assets/. public_html/lazysite-assets/default/odcc/

Then set `theme: odcc` in `lazysite.conf`.

### Theme zip format

A theme zip (uploaded via Manager > Themes > Upload theme)
must contain at minimum:

    theme.json

And typically:

    main.css
    assets/
      logo.svg
      fonts/...

`theme.json` declares metadata, compatibility, and design
tokens - see [theme.json](/docs/features/configuration/theme-json).

If a theme with the same name already exists under the target
layout, the install directory is prefixed with today's date
(e.g. `20260422-odcc`). Rename via Manager > Themes.

## Switching themes

Set `theme:` in `lazysite.conf` and clear the page cache:

    find public_html -name "*.html" -delete

Or use Manager > Cache > Clear all if the manager is enabled.
The admin-bar theme switcher (visible to managers when more
than one compatible theme is installed) does both atomically.

## Creating a layout

Writing a layout is writing a Template Toolkit file that
references the variables listed in
[layouts.md](/docs/features/configuration/layouts). The minimum:

    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>[% page_title %][% IF site_name %] - [% site_name %][% END %]</title>
      [% theme_css %]
      [% IF theme_assets %]
      <link rel="stylesheet" href="[% theme_assets %]/main.css">
      [% END %]
    </head>
    <body>
      <main>
        <h1>[% page_title %]</h1>
        [% content %]
      </main>
    </body>
    </html>

Navigation uses the `[% nav %]` array populated from `nav.conf`.
See [nav.conf](/docs/features/configuration/nav-conf).

## Asset paths

When a theme's assets (CSS, images, fonts) need to be
web-accessible, they live under
`lazysite-assets/LAYOUT/THEME/`. The processor sets
`[% theme_assets %]` to `/lazysite-assets/LAYOUT/THEME` when a
compatible theme is active. Remote layouts use a flat
`/lazysite-assets/CACHE_KEY/` path - see
[remote layouts](/docs/features/configuration/remote-layouts).

Reference in `layout.tt`:

    [% IF theme_assets %]
    <link rel="stylesheet" href="[% theme_assets %]/main.css">
    [% END %]

## Further reading

- [Layouts reference](/docs/features/configuration/layouts)
- [Themes reference](/docs/features/configuration/themes)
- [theme.json reference](/docs/features/configuration/theme-json)
- [Remote layouts](/docs/features/configuration/remote-layouts)
