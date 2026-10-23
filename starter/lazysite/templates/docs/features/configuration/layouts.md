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

Install from the catalogue on **Appearance** (`/manager/appearance`):
"Browse the repo" lists the layouts in the configured `layouts_repo`
(its `manifest.json`); installing one pulls the layout plus its
default theme (or a chosen / all themes), mirrors assets, and
activates it. An already-installed layout offers **Update** (re-pull a
changed version, keeping its themes); a non-active layout can be
**deleted** (with its themes). A layout's `components/` subtree (see
"Content components" in the layout-authoring guide) is bundled and
installed too.

The same operations are available to partners over the control API
and the MCP connector (`layout-install` / `layout-delete` /
`layouts-manifest`; `install_layout(update:true)` to redeploy).

To install by hand instead, drop `layout.tt` + `layout.json` (and any
`components/`) under `public_html/lazysite/layouts/<name>/` and set
`layout: <name>` in `lazysite.conf`.

### Layout name sanitisation

Names are sanitised to `[A-Za-z0-9_-]` at resolve time. Anything
else is stripped.

### Related

- [Themes](/docs/features/configuration/themes)
- [Remote layouts](/docs/features/configuration/remote-layouts)
