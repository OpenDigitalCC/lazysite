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

A site has ONE active layout + theme, set in `lazysite.conf`:

    layout: default
    theme: odcc

Both values are sanitised to `[A-Za-z0-9_-]` at resolve time. **Activate the
theme globally and keep pages layout-agnostic** - do not put `layout:` in page
front matter as the way to apply a design. Every page then inherits the active
layout, so the whole site re-themes in one step. A per-page `layout:` is only
for previewing a staged candidate (below) or a deliberate one-off page - and
you remove preview overrides once you activate.

Agents set these **themselves** through the control API (`layout-activate` /
`theme-activate`), which also clears the cache - it is a self-serve action with
`manage_layouts` / `manage_themes`, not an operator hand-off.

## Staging a layout over WebDAV

If you publish over WebDAV you do NOT edit the live look in place - you
stage a new layout beside the active one, preview it, and **activate it
yourself** over the control API.

1. **Capabilities come from your account, not your token.** Editing layout
   structure (including `layout.tt`) needs `manage_layouts`; theme files
   need `manage_themes` (separate capabilities). The token does not encode
   capabilities - they are read from your account on every request - so an
   operator's grant takes effect immediately and you do NOT need a new
   token. If a layout write still `403`s right after a grant, you are
   almost certainly writing the **active** layout (next point), which is
   denied regardless of capability. (Ruled that out and a fresh grant still
   seems not to apply? Rotating your token is a reliable belt-and-braces.)
2. **Stage a NEW layout dir - never the active one.** A `PUT` into the
   active layout returns `403`: the live layout is immutable in place, by
   design (a deliberate guard, not a grant failure). A path under a new
   layout returns `409` until you create its collections, then it is
   writable - so `MKCOL` `lazysite/layouts/<new>` and
   `…/themes/<theme>` first, then `PUT` the files.
3. **Preview by per-page override.** Set `layout: <new>` in a single page's
   front matter to render that page through the staged layout before any
   global switch - this is the preview mechanism. The theme's SOURCE css is
   web-served at `/lazysite/layouts/<new>/themes/<theme>/main.css`, so
   reference that for preview; the canonical mirror
   `/lazysite-assets/<new>/<theme>/main.css` is `404` until activation.
4. **Activate it yourself.** `POST` `action=layout-activate&path=<new>` then
   `action=theme-activate&path=<theme>` to the control API (needs
   `manage_layouts` / `manage_themes`); each sets the pointer in
   `lazysite.conf` AND clears the cache atomically - no operator step. Then
   **remove the per-page `layout:` preview overrides**: they are a preview
   tool, not the deploy mechanism, and left in place they quietly defeat the
   next site-wide theme switch. Once active, the canonical `/lazysite-assets/`
   mirror serves the theme CSS.

## Theme assets and the activation mirror

`main.css` and other theme assets must live under the theme's **`assets/`**
directory: `lazysite/layouts/<layout>/themes/<theme>/assets/main.css`. On
activation the server builds a flattened mirror served at
`/lazysite-assets/<layout>/<theme>/main.css`, and `layout.tt` links that mirror.

- A `main.css` at the theme ROOT (not under `assets/`) is **not** mirrored, so
  the page links a `404`. Put assets under `assets/`.
- **The mirror is rebuilt on every activation** (`theme-activate` /
  `layout-activate`), so after activating, `GET`
  `/lazysite-assets/<layout>/<theme>/main.css` returns `200` - a
  copied-then-activated layout is drop-in, with no CSS-path edits needed. If it
  ever `404`s, re-activate to rebuild it (or, as a fallback, write the mirror
  files directly over WebDAV).
- Before activation, the theme SOURCE css is web-served at
  `/lazysite/layouts/<layout>/themes/<theme>/main.css` - use that for preview;
  switch links to the `/lazysite-assets/` mirror once active.

`theme.json` must be **strict JSON, ASCII, and quote-free in values** - a
non-ASCII character (e.g. an em-dash in `description`) or embedded quotes in a
`config` value fails validation. The check runs **at activation** (and is
cached), so after fixing `theme.json` you must **re-activate**, not just
re-PUT it; a rejection now names the failing reason.

Author `.html` files in the content tree (include partials with no matching
`.md`/`.url` source) are **content, not cache** - the activation cache-clear
leaves them alone. Generated cache (`<page>.html` beside `<page>.md`) is what
gets cleared.

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
