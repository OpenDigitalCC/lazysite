---
title: Layouts
subtitle: The structural HTML template for your site.
tags:
  - configuration
  - template
---

## Layouts

A layout is the HTML chrome around every rendered page: `<head>`,
navigation, body markup, footer. Themes layer colours and fonts
on top; content pages slot into `[% content %]`.

### Setting a layout

In `lazysite.conf`:

    layout: default

The processor resolves `lazysite/layouts/default/layout.tt` and
renders every page through it. If no layout is configured or the
named layout isn't installed, the processor falls back to a
built-in minimal template (functional, not pretty).

### On-disk structure

    public_html/lazysite/layouts/default/
      layout.tt           <- the TT template (required)
      layout.json         <- metadata (optional but recommended)
      themes/             <- themes compatible with this layout
        odcc/
          theme.json
          main.css

### layout.json

    {
      "name": "default",
      "version": "1.0.0",
      "description": "Default lazysite page layout with header, main, footer",
      "author": "lazysite"
    }

**Required:** `name` (must match directory), `version` (semver).
**Optional:** `description`, `author`.

### layout.tt contract

The processor passes a known set of TT variables into `layout.tt`:

| Variable              | Type   | Notes                                               |
| --------------------- | ------ | --------------------------------------------------- |
| `content`             | HTML   | The rendered page body                              |
| `page_title`          | string | Front-matter `title`                                |
| `page_subtitle`       | string | Front-matter `subtitle`                             |
| `site_name`           | string | `lazysite.conf` `site_name`                         |
| `nav`                 | array  | Parsed `nav.conf` entries                           |
| `layout_name`         | string | Resolved layout name                                |
| `theme`               | hash   | Parsed `theme.json` (`theme.config.GROUP.KEY`)      |
| `theme_name`          | string | Resolved theme name                                 |
| `theme_assets`        | string | `/lazysite-assets/LAYOUT/THEME/` (nested)           |
| `theme_css`           | HTML   | `<style>` block with `:root` custom properties      |

When no theme is active (or an incompatible one is configured),
`theme` is an empty hash, `theme_name` is unset, and `theme_css`
is an empty string. Layouts should guard theme references:

    [% IF theme_assets %]
    <link rel="stylesheet" href="[% theme_assets %]/main.css">
    [% END %]
    [% theme_css %]

### Installing a layout

Layouts are not installed via the manager UI at 0.3.0; the
theme-browser stays theme-only. Install a layout manually:

    mkdir -p public_html/lazysite/layouts/default
    cp layout.tt   public_html/lazysite/layouts/default/
    cp layout.json public_html/lazysite/layouts/default/

Then add `layout: default` to `lazysite.conf` and install a
compatible theme on `/manager/themes`.

### Layout name sanitisation

Names are sanitised to `[A-Za-z0-9_-]` at resolve time. Anything
else is stripped.

### Related

- [Themes](/docs/features/configuration/themes)
- [Remote layouts](/docs/features/configuration/remote-layouts)
