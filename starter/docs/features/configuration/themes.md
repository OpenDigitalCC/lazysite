---
title: Themes
subtitle: Switch views site-wide or install multiple named themes.
tags:
  - configuration
  - template
---

## Themes

Themes are named view templates that can be switched site-wide via
`lazysite.conf` or per-page via the `layout:` front matter key.

### Setting a theme

In `lazysite.conf`:

    theme: mytheme

### Resolution order

When a theme name is set, lazysite checks these locations in order:

1. `lazysite/themes/NAME/view.tt` - theme directory
2. `lazysite/templates/NAME.tt` - named template file

If neither exists, falls back to `lazysite/templates/view.tt`, then
the built-in fallback.

### Theme directory structure

A theme has two parts, stored in separate locations:

    public_html/lazysite/themes/mytheme/
      view.tt
      theme.json           <- optional metadata

    public_html/lazysite-assets/mytheme/
      main.css
      logo.svg
      js/app.js            <- any static assets referenced from view.tt

The split is deliberate: `lazysite/themes/` is blocked from web
access by the Apache / Hestia template (`<Location /lazysite/>`
denies all), while `lazysite-assets/` is served as normal
static content. CSS, JS, images, and fonts go under
`lazysite-assets/NAME/`; templates go under `lazysite/themes/NAME/`.

### theme_assets TT variable

Inside `view.tt`, the `theme_assets` variable holds the URL
prefix for the active theme's assets:

    [% IF theme_assets %]
    <link rel="stylesheet" href="[% theme_assets %]/main.css">
    <script src="[% theme_assets %]/js/app.js"></script>
    [% END %]

For a theme installed at `lazysite/themes/mytheme/`,
`theme_assets` resolves to `/lazysite-assets/mytheme`. This
holds for both locally-installed themes and
[remote themes](/docs/features/configuration/remote-layouts) -
in the remote case the assets are cached under a
derived key, not the theme name.

The `[% IF theme_assets %]` guard is defensive and can be
omitted when you know a theme is always active.

### Installing a theme

**Via the manager UI.** Upload a zip containing `view.tt` and
an `assets/` subdirectory at `/manager/themes`. The manager
splits the archive automatically: `view.tt` and
`theme.json` land under `lazysite/themes/NAME/`, and the
contents of `assets/` land under `lazysite-assets/NAME/`.

**Manually.** Create both locations:

    mkdir -p public_html/lazysite/themes/clean
    cp clean-view.tt public_html/lazysite/themes/clean/view.tt

    mkdir -p public_html/lazysite-assets/clean
    cp -r clean-assets/. public_html/lazysite-assets/clean/

Then activate in `lazysite.conf`:

    theme: clean

### Theme name sanitisation

Theme names are sanitised to contain only `a-z`, `A-Z`, `0-9`, `_`,
and `-`. Any other characters are stripped. If sanitisation removes
all characters, the theme falls back to the default view.

### Notes

- Theme names can also be remote URLs - see
  [Remote layouts](/docs/features/configuration/remote-layouts)
- Per-page theme override via `layout:` in front matter takes
  precedence over the site-wide `theme:` setting
- [Per-page layout override](/docs/features/configuration/layout-override) -
  override the theme for a single page
