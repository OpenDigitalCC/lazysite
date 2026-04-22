---
title: AI briefing - layouts and themes
subtitle: Guide for AI assistants helping users author or modify a lazysite layout or theme.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This briefs an AI assistant working on the visual layer of a
lazysite site - the layout template (`layout.tt`) and its
themes. For content, see
[AI briefing - authoring](/docs/ai-briefing-authoring). For
configuration, see
[AI briefing - configuration](/docs/ai-briefing-configuration).

## Terminology (D013)

**Layout**: the Template Toolkit file (`layout.tt`) that wraps
every page. Provides `<head>`, header, navigation, footer.
Installed at `lazysite/layouts/NAME/layout.tt` with optional
`lazysite/layouts/NAME/layout.json` metadata.

**Theme**: colours, fonts, spacing, and assets that sit on top
of one or more layouts. Installed nested at
`lazysite/layouts/LAYOUT/themes/THEME/`. Declares compatibility
in `theme.json`'s `layouts[]` array.

**Manager UI**: has its own internal template at
`lazysite/manager/layout.tt`. Outside the layout+theme system.
Do not modify unless explicitly asked.

On-disk example:

    lazysite/
      layouts/
        default/
          layout.tt
          layout.json
          themes/
            odcc/
              theme.json
              main.css
              assets/
      manager/
        layout.tt
        assets/manager.css
    lazysite-assets/
      default/
        odcc/
          main.css
          assets/

## TT variables in layout.tt

Always available:

- `content` - rendered HTML page body
- `page_title`, `page_subtitle` - front-matter values
- `site_name` - from `lazysite.conf`
- `nav` - array parsed from `nav.conf`
- `request_uri` - current URL path

D013 additions:

- `layout_name` - resolved layout name (string)
- `theme_name` - resolved theme name when a compatible theme is
  active (string; unset otherwise)
- `theme` - hash, the parsed `theme.json`. Access config values
  as `[% theme.config.colours.primary %]` etc. Empty hash when
  no theme is active.
- `theme_assets` - URL prefix `/lazysite-assets/LAYOUT/THEME`
  (nested for local themes), or `/lazysite-assets/CACHE_KEY` for
  remote layouts (flat), or unset when no theme
- `theme_css` - pre-rendered `<style>:root { ... }` block of CSS
  custom properties. Empty string when no theme.

Auth variables:

- `authenticated` - truthy if the request has a valid session
- `auth_user`, `auth_name`, `auth_groups` - user identity
- `manager` - "enabled"/"disabled" from conf
- `manager_path` - manager UI URL path

## theme.json schema (D013)

Required fields:

- `name` - matches directory name
- `version` - semver
- `description` - free text
- `author` - free text
- `layouts` - array of layout names this theme is compatible
  with. **The manager rejects an upload without this.** The
  processor ignores a theme if the active layout isn't in this
  array.
- `config` - object grouping design tokens. Common groups:
  `colours`, `fonts`, `spacing`, `icons`. Group names and keys
  are author-chosen; values must be strings.

Optional:

- `files` - list of files shipped. Used for remote-layout auto-
  fetch; not consulted for local themes.

Example:

    {
      "name": "odcc",
      "version": "1.0.0",
      "description": "OpenDigitalCC brand theme",
      "author": "OpenDigitalCC",
      "layouts": ["default"],
      "config": {
        "colours": {
          "primary": "#332b82",
          "text": "#2a2a2a"
        },
        "fonts": {
          "body": "Open Sans"
        }
      },
      "files": ["theme.json", "main.css"]
    }

## Auto-generated CSS variables

The processor walks `theme.config` and emits a `<style>` block
with CSS custom properties at `:root`, exposed as
`[% theme_css %]`:

    <style>
    :root {
      --theme-colours-primary: #332b82;
      --theme-colours-text: #2a2a2a;
      --theme-fonts-body: Open Sans;
    }
    </style>

Naming: `--theme-GROUP-KEY`.

Use in the theme's CSS:

    body {
      color: var(--theme-colours-text);
      font-family: var(--theme-fonts-body);
    }

This is the recommended pattern: layout.tt emits `theme_css`;
the theme's own `main.css` references the variables. A theme
fork that only tweaks colours edits `theme.json` and doesn't
need to duplicate CSS structure.

## Minimum layout.tt

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
      [% IF nav.size %]
      <nav>
        [% FOREACH item IN nav %]
        <a href="[% item.url %]">[% item.label %]</a>
        [% END %]
      </nav>
      [% END %]
      <main>
        <h1>[% page_title %]</h1>
        [% IF page_subtitle %]<p>[% page_subtitle %]</p>[% END %]
        [% content %]
      </main>
    </body>
    </html>

## Activating layout + theme

In `lazysite.conf`:

    layout: default
    theme: odcc

Both values are sanitised to `[A-Za-z0-9_-]` at resolve time.

## Theme incompatibility

If `theme.json.layouts` does NOT contain the active layout:

- The processor logs a WARN: `theme not declared for layout`
- `theme_css` is empty
- `theme_assets` is unset
- `theme` is an empty hash
- The page still renders through layout.tt

## What NOT to do

- Do not modify `lazysite/manager/layout.tt` - that's the
  manager UI's internal chrome.
- Do not place themes at the pre-D013 path
  `lazysite/themes/NAME/` - the processor doesn't look there
  any more.
- Do not write `view.tt` - that file name is gone; it's
  `layout.tt` now.
- Do not omit `layouts[]` from `theme.json` - the manager
  rejects the upload and the processor can't activate it.
- Do not emit CSS expressions in `theme.config` values; `;{}<>`
  are stripped to prevent declaration escape.

## Related

- [Layouts reference](/docs/features/configuration/layouts)
- [Themes reference](/docs/features/configuration/themes)
- [theme.json reference](/docs/features/configuration/theme-json)
- [Remote layouts](/docs/features/configuration/remote-layouts)
