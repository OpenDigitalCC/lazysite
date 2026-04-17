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

    public_html/lazysite/themes/mytheme/
      view.tt

### Theme name sanitisation

Theme names are sanitised to contain only `a-z`, `A-Z`, `0-9`, `_`,
and `-`. Any other characters are stripped. If sanitisation removes
all characters, the theme falls back to the default view.

### Example

Install a theme:

    mkdir -p public_html/lazysite/themes/clean
    cp clean-view.tt public_html/lazysite/themes/clean/view.tt

Activate it in `lazysite.conf`:

    theme: clean

### Notes

- Theme names can also be remote URLs - see
  [Remote layouts](/docs/features/configuration/remote-layouts)
- Per-page theme override via `layout:` in front matter takes
  precedence over the site-wide `theme:` setting
- [Per-page layout override](/docs/features/configuration/layout-override) -
  override the theme for a single page
