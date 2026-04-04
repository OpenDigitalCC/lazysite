---
title: Configuration
subtitle: Views, navigation, site variables, and themes.
register:
  - sitemap.xml
  - llms.txt
---

## Views

`lazysite/templates/view.tt` controls the visual presentation of every page.
lazysite includes a built-in fallback view so it works with no configuration
files. For a styled site, install a view from [lazysite-views][views].

### Installing a view

    curl -o public_html/lazysite/templates/view.tt \
      https://raw.githubusercontent.com/OpenDigitalCC/lazysite-views/main/default/view.tt

Or clone the views repository and copy the directory you want:

    git clone https://github.com/OpenDigitalCC/lazysite-views.git
    cp lazysite-views/default/view.tt public_html/lazysite/templates/

### What the view template receives

Every page render passes these variables to view.tt:

`[% page_title %]`
: The page title from front matter.

`[% page_subtitle %]`
: The page subtitle from front matter. May be empty - test with
  `[% IF page_subtitle %]`.

`[% content %]`
: The converted page body as HTML. Output with `[% content %]` - TT does
  not escape this value.

`[% page_modified %]`
: Human-readable file modification date, e.g. "3 April 2026".

`[% page_modified_iso %]`
: ISO 8601 file modification date, e.g. "2026-04-03". Useful for
  `<time datetime="...">` elements.

`[% nav %]`
: Navigation array loaded from `nav.conf`. See navigation section below.

`[% request_uri %]`
: The current page path, e.g. `/about`. Set from the `${REDIRECT_URL}`
  environment variable. Useful for highlighting the active navigation item.

Plus all site-wide variables defined in `lazysite.conf`.

### Minimal view template

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>[% page_title %][% IF site_name %] - [% site_name %][% END %]</title>
</head>
<body>
<header>
    <a href="/">[% site_name %]</a>
    <nav>
    [% FOREACH item IN nav %]
      [% IF item.url %]
      <a href="[% item.url %]"
        [% IF request_uri == item.url %]aria-current="page"[% END %]>
        [% item.label %]</a>
      [% ELSE %]
      <span>[% item.label %]</span>
      [% END %]
      [% FOREACH child IN item.children %]
        <a href="[% child.url %]">[% child.label %]</a>
      [% END %]
    [% END %]
    </nav>
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

### After changing the view template

Delete all cached `.html` files to force regeneration:

    find public_html -name "*.html" -delete

### Theme metadata

Include a TT comment block at the top of `view.tt` to document the theme:

```
[%#
  name: My Theme
  version: 1.0.0
  author: Your Name
  requires: 0.9.0
  description: Brief description of the theme.
%]
```

### Themes directory

Multiple views can be installed in `lazysite/themes/`:

    public_html/lazysite/themes/dark/view.tt
    public_html/lazysite/themes/minimal/view.tt

Switch site-wide in `lazysite.conf`:

    theme: dark

Override per-page in front matter:

    layout: minimal

The processor checks `lazysite/themes/NAME/view.tt` first, then
`lazysite/templates/NAME.tt`, and falls back to the default `view.tt`.

### Remote views

A view can be loaded from a URL by setting `theme:` to a full URL in
`lazysite.conf`:

    theme: https://raw.githubusercontent.com/OpenDigitalCC/lazysite-views/main/default/view.tt

The remote view is fetched and cached locally. It is refreshed after the
remote TTL expires (default 1 hour). Remote views run in a restricted
Template Toolkit instance - embedded Perl and relative includes are
disabled.

## Navigation

`lazysite/nav.conf` defines the site navigation as a plain text file.
The processor reads it into a `nav` TT variable available in every page.

### Format

    # Comments start with #
    # Blank lines are ignored

    Home | /
    About | /about
    Docs | /docs/
      Installation | /docs/install
      Authoring | /docs/authoring
    Resources
      GitHub | https://github.com/example

Rules:

- `Label | /url` - clickable item
- `Label` with no pipe - non-clickable group heading
- Leading whitespace (any amount) - child of the preceding item
- One level of nesting supported (parent + children)
- Lines starting with `#` - comments

### nav TT variable structure

`nav` is an array of hashrefs. Each item has `label`, `url`, and
`children` keys:

```
[% FOREACH item IN nav %]
  [% IF item.url %]
  <a href="[% item.url %]"
    [% IF request_uri == item.url %]aria-current="page"[% END %]>
    [% item.label %]</a>
  [% ELSE %]
  <span class="nav-group">[% item.label %]</span>
  [% END %]
  [% IF item.children.size %]
  <ul>
    [% FOREACH child IN item.children %]
    <li><a href="[% child.url %]"
      [% IF request_uri == child.url %]aria-current="page"[% END %]>
      [% child.label %]</a></li>
    [% END %]
  </ul>
  [% END %]
[% END %]
```

If `nav.conf` is missing, `nav` is an empty array and the template
renders without navigation.

### Alternate nav file

Override the default nav file path in `lazysite.conf`:

    nav_file: lazysite/docs-nav.conf

The path is relative to the docroot.

## Page scan

The `scan:` prefix in `lazysite.conf` or `tt_page_var` scans a
directory and returns an array of page metadata as a TT variable.

    blog_pages: scan:/blog/*.md

In a page body:

    [% FOREACH post IN blog_pages %]
    ## [% post.title %]
    [% post.subtitle %] - [% post.date %]
    [% END %]

### Pattern rules

- Pattern must start with `/` (docroot-relative path)
- Only `*.md` files are matched
- One level of directory only - no recursive scanning
- Maximum 200 files per scan
- Each result is realpath-checked - rejected if outside docroot

### Page object fields

Each item in the returned array has:

- `url` - extensionless URI, e.g. `/blog/first-post`
- `title` - from front matter `title:`
- `subtitle` - from front matter `subtitle:` (may be empty)
- `date` - from front matter `date:`, falls back to file mtime
- `path` - absolute filesystem path (useful for debugging)

### Sort order

Default sort is by filename. Use the `sort=` modifier to sort by field:

    blog_pages: scan:/blog/*.md sort=date desc
    news_pages: scan:/news/*.md sort=title asc

Sort fields: `date`, `title`, `filename`. Direction: `asc` or `desc`.
Default direction is `asc`.

For reverse-chronological blog posts, use `sort=date desc`. Date-prefix
filenames (`2026-03-20-post-title.md`) also sort chronologically by
filename without needing the sort modifier.

### Per-page scan

Scan variables work in `tt_page_var` for page-scoped results:

```yaml
tt_page_var:
  section_pages: scan:/services/*.md sort=title asc
```

## lazysite.conf

`lazysite/lazysite.conf` defines site-wide variables available in
`view.tt` and all page bodies.

### Format

One variable per line. Three value types:

    # Literal string
    site_name: My Site

    # Environment variable (CGI - allowlisted vars only)
    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}

    # Remote URL fetch (trimmed, cached with page TTL)
    version: url:https://raw.githubusercontent.com/example/repo/main/VERSION

### Standard variables

Always define these two:

    site_name: My Site
    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}

`site_url` uses Apache CGI environment variables set automatically on every
request. Do not hardcode the domain - the same `lazysite.conf` works on
staging and production.

### Allowlisted environment variables

Only these CGI environment variables may be used with `${VAR}` syntax:
`SERVER_NAME`, `REQUEST_SCHEME`, `SERVER_PORT`, `HTTPS`, `REDIRECT_URL`,
`DOCUMENT_ROOT`, `SERVER_ADMIN`.

`${REDIRECT_URL}` contains the requested page path (e.g. `/about`). Set it
as `request_uri` in `lazysite.conf` to make it available in `view.tt` for
active navigation highlighting:

    request_uri: ${REDIRECT_URL}

### Optional settings

    theme: dark               <- named theme or remote URL
    nav_file: lazysite/alt-nav.conf  <- alternate navigation file

[views]: https://github.com/OpenDigitalCC/lazysite-views
[github]: https://github.com/OpenDigitalCC/lazysite
