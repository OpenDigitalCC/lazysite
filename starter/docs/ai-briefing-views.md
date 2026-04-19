---
title: AI briefing - views and themes
subtitle: Guide for AI assistants helping users author or modify a lazysite theme.
register:
  - sitemap.xml
  - llms.txt
---

## Who this is for

This briefs an AI assistant working on the visual layer of a lazysite
site - the view template (`view.tt`) and theme assets. For content, see
[AI briefing - authoring](/docs/ai-briefing-authoring). For configuration,
see [AI briefing - configuration](/docs/ai-briefing-configuration).

## What a view is

A view is a Template Toolkit file (`view.tt`) that wraps every page on
the site. The processor converts the page body to HTML, then renders it
inside the view at `[% content %]`. The view provides the `<head>`, the
header, the navigation, and the footer.

A theme is a view plus everything it needs to render: CSS, fonts,
images, and an optional `theme.json` manifest. Themes live under
`lazysite/themes/THEMENAME/` in the docroot.

```
lazysite/themes/
  default/
    view.tt
    theme.json
    assets/
      main.css
      fonts/
```

## Manager theme

The theme at `lazysite/themes/manager/` is a system theme used by the
`/manager` UI. Do not modify it unless explicitly asked. When the user
asks for "a theme" or "the site theme", assume they mean the active
site theme, not the manager theme.

## TT variables in view.tt

These variables are always available in the view:

`page_title`
: Page title from front matter.

`page_subtitle`
: Page subtitle from front matter. May be empty.

`page_modified`
: Human-readable file mtime, e.g. "3 April 2026".

`page_modified_iso`
: ISO 8601 file mtime, e.g. "2026-04-03".

`content`
: Rendered page body as HTML. Output with `[% content %]` (TT does not
  escape this).

`request_uri`
: Current request path, e.g. `/about`. Useful for active nav
  highlighting.

`page_source`
: Docroot-relative path of the source `.md` file.

`nav`
: Navigation array from `nav.conf`.

`query`, `params`
: Query parameter hash (only populated when `query_params:` is declared
  in the page). `params` is an alias for `query`.

`year`
: Current year as a 4-digit string, e.g. `2026`. Useful for footer
  copyright lines.

`search_enabled`
: `1` if `search-results.md` (or `.url`) exists in the docroot, `0`
  otherwise. Use to conditionally render a search box.

`site_name`, `site_url`
: From `lazysite.conf`.

`theme`
: Active theme name.

`theme_assets`
: Asset path for remote themes. Set to `/lazysite-assets/NAME` when a
  remote theme is in use.

### Auth variables

`authenticated`
: `1` if the request has valid auth headers, `0` otherwise.

`auth_user`
: Username, or empty string.

`auth_name`
: Display name.

`auth_email`
: Email address.

`auth_groups`
: Array of group names.

`editor`
: `1` if the current user has manager access (authenticated and in
  `manager_groups`), `0` otherwise. Use to gate admin UI in views.

### Custom variables

Any key defined in `lazysite.conf` becomes a TT variable. So does any
key in the page's `tt_page_var` block. Page variables override site
variables of the same name.

## Navigation structure

`nav` is an array of hashrefs. Each item has `label`, `url`, and
optional `children`:

```tt2
[% FOREACH item IN nav %]
  [% IF item.url %]
    <a href="[% item.url %]"
       [% IF request_uri == item.url %]aria-current="page"[% END %]>
      [% item.label %]
    </a>
  [% ELSE %]
    <span class="nav-group">[% item.label %]</span>
  [% END %]
  [% IF item.children.size %]
    <ul>
      [% FOREACH child IN item.children %]
        <li>
          <a href="[% child.url %]"
             [% IF request_uri == child.url %]aria-current="page"[% END %]>
            [% child.label %]
          </a>
        </li>
      [% END %]
    </ul>
  [% END %]
[% END %]
```

If `nav.conf` is missing, `nav` is an empty array.

## Conditional blocks

```tt2
[% IF site_name %]
  <title>[% page_title %] - [% site_name %]</title>
[% ELSE %]
  <title>[% page_title %]</title>
[% END %]
```

Use `[% IF authenticated %]` to show UI only to logged-in users.

## Asset paths

For themes with a `theme.json` manifest, the manager copies assets into
`lazysite-assets/THEMENAME/` and sets `[% theme_assets %]` accordingly:

```html
[% IF theme_assets %]
<link rel="stylesheet" href="[% theme_assets %]/main.css">
[% END %]
```

For themes without a manifest, reference assets with a hardcoded path
(e.g. `/lazysite/themes/NAME/assets/main.css` is not web-accessible;
copy to `/assets/` or `/lazysite-assets/NAME/`).

## theme.json format

```json
{
  "name": "mytheme",
  "description": "My custom theme",
  "version": "1.0",
  "files": ["view.tt", "assets/main.css"]
}
```

The manager uses `theme.json` to validate and activate theme uploads.

## Installing a view

### Manager upload

If the manager is enabled, upload a theme zip at Manager > Themes.
The manager extracts the zip to `lazysite/themes/THEMENAME/`, copies
assets to `lazysite-assets/THEMENAME/` (if a manifest declares them),
and activates the theme.

### Manual install

    curl -L https://github.com/OpenDigitalCC/lazysite-views/raw/main/releases/default.zip \
      -o /tmp/default.zip
    mkdir -p DOCROOT/lazysite/themes/default
    unzip /tmp/default.zip -d DOCROOT/lazysite/themes/default/

Then set the active theme in `lazysite.conf`:

    theme: default

Clear cached pages so they regenerate through the new view:

    find DOCROOT -name "*.html" -delete

## Tasks

### Creating a minimal view.tt

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>[% page_title %][% IF site_name %] - [% site_name %][% END %]</title>
  [% IF theme_assets %]
  <link rel="stylesheet" href="[% theme_assets %]/main.css">
  [% END %]
</head>
<body>
  <header>
    <a href="/">[% site_name %]</a>
  </header>
  <main>
    <h1>[% page_title %]</h1>
    [% IF page_subtitle %]<p>[% page_subtitle %]</p>[% END %]
    [% content %]
  </main>
  <footer>
    <p>Built with <a href="https://lazysite.io">lazysite</a></p>
  </footer>
</body>
</html>
```

### Adding navigation with dropdown support

Use the `nav` variable with nested children (see above).

### Adding auth UI (sign in / sign out)

```tt2
[% IF authenticated %]
  <span>Signed in as [% auth_name || auth_user %]</span>
  <a href="/logout">Sign out</a>
[% ELSE %]
  <a href="/login">Sign in</a>
[% END %]
```

### Adding a search box

Gate on `search_enabled` so the box only appears when the search
results page is deployed:

```tt2
[% IF search_enabled %]
<form action="/search-results" method="get" role="search">
  <input type="search" name="q" placeholder="Search">
  <button type="submit">Search</button>
</form>
[% END %]
```

The `/search-results` page handles rendering. Search visibility per
page is controlled by the `search:` front matter key.

### Adding editor bar support

Render admin controls only for users with manager access:

```tt2
[% IF editor %]
  <a href="/manager/">Manage</a>
  <a href="/manager/edit?path=[% page_source %]">Edit</a>
[% END %]
```

The processor also injects its own admin bar (Manage, Edit, theme
switcher, sign out) for authenticated manager users on non-manager
pages when `manager: enabled` is set. The view does not need to render
this - it is added by the processor. Leave ~28px of top-of-body space
if you want to avoid overlap. Use `[% IF editor %]` when you want the
view to render its own in-template controls rather than relying on the
injected bar.
