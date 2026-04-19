---
title: Views and Themes
subtitle: How lazysite wraps page content in HTML layouts.
register:
  - sitemap.xml
  - llms.txt
---

## What is a view

Every page on a lazysite site is rendered through a view. The processor
converts the page's Markdown to HTML, then passes it to the view as
the `[% content %]` variable. The view provides the surrounding HTML
structure: `<head>`, navigation, header, footer, and styling.

view
: The `view.tt` Template Toolkit file. Defines the full HTML structure
  of every page on the site.

theme
: A view packaged with its assets - CSS, fonts, images. Installed as
  a directory under `lazysite/themes/`. A theme is a view plus
  everything it needs to render.

## The built-in fallback

lazysite includes a built-in minimal view embedded in the processor.
It activates automatically when no `view.tt` is found. The fallback
is functional but intentionally plain - it renders content, navigation,
search, auth state, and an edit button when the editor is enabled.

The fallback footer always notes that it is active:
`no view.tt found, using built-in fallback`

If the fallback appears unexpectedly, check:

- Is `theme:` set in `lazysite.conf` and does the theme directory exist?
- Does `lazysite/themes/THEMENAME/view.tt` exist and parse without errors?
- Check the Apache error log or dev server output for Template Toolkit errors

## How the processor finds a view

The processor checks these locations in order:

1. `layout:` in the page's front matter - overrides for a single page
2. `lazysite_theme` cookie - set by the theme switcher
3. `theme:` in `lazysite.conf` - applies site-wide
4. `lazysite/templates/view.tt` - default location
5. Built-in fallback

For each named theme, the processor checks:

- `lazysite/themes/THEMENAME/view.tt` (theme directory)
- `lazysite/templates/THEMENAME.tt` (named template)

Example `lazysite.conf`:

    site_name: My Site
    theme: default

Example single-page override in front matter:

    ---
    title: Landing Page
    layout: campaign
    ---

The `layout:` value follows the same resolution - checks the themes
directory, then templates directory.

## Installing a theme

### From lazysite-views

The [lazysite-views](https://github.com/OpenDigitalCC/lazysite-views)
repository provides ready-to-use themes. Each theme is available as a
zip package in the `releases/` directory.

Download and install manually:

    cd /home/username/web/example.com/public_html

    curl -sL https://github.com/OpenDigitalCC/lazysite-views/raw/main/releases/default.zip \
        -o /tmp/default.zip

    mkdir -p lazysite/themes/default
    unzip /tmp/default.zip -d lazysite/themes/default/

    mkdir -p lazysite-assets/default
    cp -r lazysite/themes/default/assets/* lazysite-assets/default/

Then set in `lazysite/lazysite.conf`:

    theme: default

### Via the editor

If the lazysite editor is enabled, upload a theme zip via
Editor > Themes > Upload theme. The editor validates the zip contents,
extracts to `lazysite/themes/`, copies assets to `lazysite-assets/`,
and allows activation without editing config files.

See [editor documentation](/docs/editor) for details.

### Theme zip format

A theme zip must contain at minimum:

    view.tt
    theme.json

Optional but recommended:

    nav.conf
    assets/main.css
    assets/ (any other CSS, fonts, images)

The `theme.json` file identifies the theme:

    {
      "name": "mytheme",
      "description": "My custom theme",
      "version": "1.0",
      "files": ["view.tt", "assets/main.css"]
    }

If a theme with the same name already exists, the editor prefixes
the install directory with today's date (e.g. `20260418-mytheme`).
Rename via Editor > Themes.

## Switching themes

Set `theme:` in `lazysite/lazysite.conf`:

    theme: dark

Then clear the page cache so all pages regenerate with the new theme:

    find public_html -name "*.html" -delete

Or use Editor > Cache > Clear all if the editor is enabled.

## The theme switcher

The default and dark themes include a built-in theme switcher that
lets visitors toggle between light and dark mode. The switcher reads
and writes a `lazysite_theme` cookie. The processor reads this cookie
to select the appropriate view.

The switcher requires both `default` and `dark` themes to be installed.
Each view declares the available themes in its JS - add new theme
names to the array to include them in the rotation.

## Creating a custom view

Creating a view requires writing a Template Toolkit file that uses
the variables the processor provides. The full variable reference,
design guidance, and CSS class conventions are documented in the
[lazysite-views](https://github.com/OpenDigitalCC/lazysite-views)
repository in `docs/creating-views.md`.

The minimum working view:

    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>[% page_title %][% IF site_name %] - [% site_name %][% END %]</title>
    </head>
    <body>
      <main>
        <h1>[% page_title %]</h1>
        [% content %]
      </main>
    </body>
    </html>

Navigation uses the `[% nav %]` array populated from `nav.conf`. See
[nav.conf](/docs/features/configuration/nav-conf) for the file format.

Package your theme for distribution or editor upload:

    cd lazysite-views/
    bash tools/package-themes.sh

## Asset paths

When a theme's assets (CSS, images, fonts) need to be web-accessible,
place them in `lazysite-assets/THEMENAME/` in the docroot. The
processor sets `[% theme_assets %]` to `/lazysite-assets/THEMENAME`
when a theme with a `theme.json` manifest is active.

Reference in `view.tt`:

    [% IF theme_assets %]
    <link rel="stylesheet" href="[% theme_assets %]/main.css">
    [% END %]

For locally installed themes without `theme.json`, reference assets
with a hardcoded path or use inline CSS in the view.

## Further reading

- [Configuration](/docs/configuration) - views, nav.conf, lazysite.conf
- [Views feature reference](/docs/features/configuration/views) - quick reference
- [Themes feature reference](/docs/features/configuration/themes) - theme resolution
- [lazysite-views](https://github.com/OpenDigitalCC/lazysite-views) - ready-to-use themes
