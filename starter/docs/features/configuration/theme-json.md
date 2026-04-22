---
title: theme.json
subtitle: Theme manifest - metadata, layout compatibility, design tokens, file list.
tags:
  - configuration
  - template
  - theme
---

## theme.json

Every theme ships a `theme.json` at its root declaring metadata,
the layouts it's compatible with, design tokens, and the list of
files shipped. The manager UI validates this manifest on upload;
the processor reads `config` to generate `theme_css`.

### Location

For local themes:

    public_html/lazysite/layouts/LAYOUT/themes/THEME/theme.json

For remote layouts (which bundle a theme in the same URL
directory):

    https://example.com/layouts/clean/theme.json

### Format

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
        "spacing": {
          "unit": "8px"
        }
      },
      "files": [
        "theme.json",
        "main.css",
        "assets/logo.svg"
      ]
    }

### Required fields

- `name` - matches the directory name. Sanitised to
  `[A-Za-z0-9_-]` on read.
- `version` - semver string.
- `description` - free-text, human-readable.
- `author` - free-text.
- `layouts` - array of layout names this theme is compatible
  with. The manager rejects an upload whose `layouts` field is
  missing or empty (DP-C, strict). The processor refuses to
  apply a theme to any layout not in this list.
- `config` - object grouping design tokens. Group names are
  author-chosen (common: `colours`, `fonts`, `spacing`, `icons`).
  Keys within groups are author-chosen. Values must be strings.

### Optional fields

- `files` - array of paths shipped with the theme. Used by
  remote-layout auto-fetch (downloads each listed file alongside
  the layout). Not consulted for local themes on upload; the zip
  contents dictate what lands on disk.

### Auto-generated CSS variables

The processor walks `config` and emits a `<style>:root { ... }`
block exposed as `[% theme_css %]`. Naming convention:

    --theme-GROUP-KEY

So `config.colours.primary = "#332b82"` becomes
`--theme-colours-primary: #332b82`. Values are emitted verbatim
except `;{}<>` characters which are stripped to prevent
declaration escape.

### theme_assets variable

`[% theme_assets %]` is set to:

- Local theme: `/lazysite-assets/LAYOUT/THEME/`
- Remote layout: `/lazysite-assets/CACHE_KEY/`

### Validation summary

| Condition                         | Result                 |
| --------------------------------- | ---------------------- |
| `name` missing or unsanitisable   | Install rejected       |
| `layouts` missing or empty        | Install rejected       |
| Declared layout not installed     | Install rejected       |
| Active layout not in `layouts[]`  | Theme ignored at render |
| `config` not an object            | `theme_css` empty      |
| Nested group value (not a scalar) | Value skipped silently |

### Notes

- `files[]` paths containing `..` are skipped (traversal
  protection).
- Subdirectories in `files[]` are created automatically when
  fetching remote assets.
- [Themes](/docs/features/configuration/themes) - activation
  and on-disk structure
- [Layouts](/docs/features/configuration/layouts) - the
  structural template themes sit on top of
- [Remote layouts](/docs/features/configuration/remote-layouts) -
  remote asset fetching
