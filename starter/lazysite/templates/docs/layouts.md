---
title: Layouts and Themes
subtitle: How lazysite wraps page content in HTML layouts.
register:
  - sitemap.xml
---

## Who this is for

A person running or building the site: what a layout and a theme are, where they
live, how the engine picks them, and how to install and switch them by hand or in
the manager. An AI agent changing a layout or theme reads
[AI briefing - layouts and themes](/docs/ai-briefing-layouts) as well, which has
the template contract, the `theme.json` schema and how an agent stages and
activates a change.

[% IF design_guide %]**This site's design guide:** <a href="[% design_guide %]">[% design_guide %]</a> -
how this site's own design is put together. Read it before you change its look.[% END %]

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
  Installed nested at `lazysite/layouts/LAYOUT/themes/THEME/`,
  and declares the layouts it fits in `theme.json`'s `layouts[]`
  array. Web-accessible assets mirror to
  `/lazysite-assets/LAYOUT/THEME/`.

On disk:

    lazysite/
      layouts/
        default/
          layout.tt
          layout.json
          themes/
            mytheme/
              theme.json
              main.css
              assets/
      manager/
        layout.tt
        assets/manager.css
    lazysite-assets/
      default/
        mytheme/
          main.css
          assets/

The manager has its own internal template at
`lazysite/manager/layout.tt`, outside the layout and theme system.

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
`lazysite/layouts/NAME/layout.tt`. Both `layout:` and `theme:`
are sanitised to `[A-Za-z0-9_-]` at resolve time.

A remote URL in `layout:` is fetched and cached; see
[remote layouts](/docs/features/configuration/remote-layouts).

## How the processor resolves a theme

1. `theme:` in `lazysite.conf`
2. The theme's `theme.json` at
   `lazysite/layouts/LAYOUT/themes/THEME/theme.json` is parsed
3. `theme.json.layouts[]` must contain the active layout; if
   it doesn't, the theme is ignored (no styling) and the page
   renders layout-only

When `theme.json.layouts` does not contain the active layout:

- The processor logs a WARN: `theme not declared for layout`
- `theme_css` is empty
- `theme_assets` is unset
- `theme` is an empty hash
- The page still renders through layout.tt

## Example `lazysite.conf`

    site_name: My Site
    layout: default
    theme: mytheme

## Single-page override

    ---
    title: Landing Page
    layout: campaign
    ---

## Installing a theme

### Via the manager

On `/manager/appearance`, click "Browse releases" to list published
releases of the configured `layouts_repo`. Each release zipball
may carry multiple themes; each installs once per layout it
declares compatibility with.

### Manually

Create the nested directory and drop files:

    mkdir -p public_html/lazysite/layouts/default/themes/mytheme
    cp -r mytheme/. public_html/lazysite/layouts/default/themes/mytheme/

    mkdir -p public_html/lazysite-assets/default/mytheme
    cp -r mytheme/assets/. public_html/lazysite-assets/default/mytheme/

Then set `theme: mytheme` in `lazysite.conf`.

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
(e.g. `20260422-mytheme`). Rename via Manager > Themes.

## Switching themes

Set `theme:` in `lazysite.conf` and clear the page cache:

    find public_html -name "*.html" -delete

Or use Manager > Cache > Clear all if the manager is enabled.
The admin-bar theme switcher (visible to managers when more
than one compatible theme is installed) does both atomically.
An agent switches through the control API instead - see
[Activating layout + theme](/docs/ai-briefing-layouts#activatinglayouttheme).

## Creating a layout

Writing a layout is writing a Template Toolkit file that
references the variables listed in
[layouts.md](/docs/features/configuration/layouts). A working
starting point is the
[minimum layout.tt](/docs/ai-briefing-layouts#minimumlayout.tt)
in the layouts briefing, and its
[`<head>` contract](/docs/ai-briefing-layouts#theheadcontract)
says which variables belong in `<title>` and the description.

Navigation uses the `[% nav %]` array populated from `nav.conf`.
See [nav.conf](/docs/features/configuration/nav-conf).

## Asset paths

When a theme's assets (CSS, images, fonts) need to be
web-accessible, they live under
`lazysite-assets/LAYOUT/THEME/`. The processor sets
`[% theme_assets %]` to `/lazysite-assets/LAYOUT/THEME` when a
compatible theme is active, and a layout links its stylesheet
from there. Remote layouts use a flat
`/lazysite-assets/CACHE_KEY/` path - see
[remote layouts](/docs/features/configuration/remote-layouts).
How the mirror is built on activation, and what to do when it
answers `404`, is in
[Theme assets and the activation mirror](/docs/ai-briefing-layouts#themeassetsandtheactivationmirror).

## Further reading

- [AI briefing - layouts and themes](/docs/ai-briefing-layouts)
- [Layouts reference](/docs/features/configuration/layouts)
- [Themes reference](/docs/features/configuration/themes)
- [theme.json reference](/docs/features/configuration/theme-json)
- [Remote layouts](/docs/features/configuration/remote-layouts)
