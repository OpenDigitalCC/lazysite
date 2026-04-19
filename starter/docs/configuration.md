---
title: Configuration
subtitle: Views, navigation, site variables, forms, auth, and plugins.
register:
  - sitemap.xml
  - llms.txt
---

## lazysite.conf

`lazysite/lazysite.conf` defines site-wide variables available in
`view.tt` and all page bodies. It is a plain text file with one
key-value pair per line.

### Minimal example

    site_name: My Site
    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}

`site_url` uses Apache CGI environment variables set automatically on
every request. Do not hardcode the domain - the same `lazysite.conf`
works on staging and production.

### Value types

    # Literal string
    site_name: My Site

    # Environment variable (CGI - allowlisted vars only)
    site_url: ${REQUEST_SCHEME}://${SERVER_NAME}

    # Remote URL fetch (trimmed, cached with page TTL)
    version: url:https://raw.githubusercontent.com/example/repo/main/VERSION

    # Directory scan (array of page metadata)
    blog_pages: scan:/blog/*.md sort=date desc

### Recognised keys

`site_name`
: Display name of the site.

`site_url`
: Full URL of the site. Typically
  `${REQUEST_SCHEME}://${SERVER_NAME}`.

`theme`
: Active theme. The processor loads
  `lazysite/themes/THEME/view.tt`. May also be a full remote URL.

`nav_file`
: Navigation file path, docroot-relative. Default:
  `lazysite/nav.conf`.

`search_default`
: Site-wide default for the `search:` front matter key. `true` (default)
  or `false`.

`manager`
: `enabled` or `disabled`. Controls the built-in manager at `/manager`.

`manager_path`
: URL path for the manager. Default: `/manager`.

`manager_groups`
: Comma-separated groups. Only users in these groups can access the
  manager.

`log_level`
: `ERROR`, `WARN`, `INFO` (default), or `DEBUG`.

`log_format`
: `text` (default) or `json`.

`plugins`
: List of plugin script paths to pre-enable without using the manager
  UI.

`auth_default`
: Site-wide default for the `auth:` front matter key. `required`,
  `optional`, or `none` (default).

`auth_header_user`, `auth_header_name`, `auth_header_email`, `auth_header_groups`
: Override HTTP header names when using an external auth proxy.
  Defaults: `X-Remote-User`, `X-Remote-Name`, `X-Remote-Email`,
  `X-Remote-Groups`.

All other keys become TT variables available in page content and the
view template.

### Example

```yaml
site_name: My Site
site_url: ${REQUEST_SCHEME}://${SERVER_NAME}
theme: default
nav_file: lazysite/nav.conf
search_default: true
log_level: INFO
log_format: text
manager: enabled
manager_path: /manager
manager_groups: lazysite-admins
plugins:
  - cgi-bin/lazysite-auth.pl
  - cgi-bin/lazysite-form-handler.pl
```

### Allowlisted environment variables

Only these CGI variables may be used with `${VAR}` syntax:
`SERVER_NAME`, `REQUEST_SCHEME`, `SERVER_PORT`, `HTTPS`, `REDIRECT_URL`,
`DOCUMENT_ROOT`, `SERVER_ADMIN`.

`HTTP_HOST` is intentionally excluded - it is request-supplied and
therefore untrusted. Use `SERVER_NAME` for host-based URL construction.

## Navigation (nav.conf)

`lazysite/nav.conf` defines the site navigation. The processor reads
it into a `nav` TT variable available in every page.

### Format

Navigation is YAML. Items may be links, group headings, or groups with
nested children:

```yaml
- label: Home
  url: /
- label: About
  url: /about
- label: Docs
  children:
    - label: Install
      url: /docs/install
    - label: Authoring
      url: /docs/authoring
- label: Resources
  children:
    - label: GitHub
      url: https://github.com/example
```

Rules:

- Items with a `url` render as links
- Items without `url` render as non-clickable headings
- `children` provides one level of nesting
- One level of nesting is supported (parent with children)

### Legacy pipe format

An older pipe-separated format is also accepted:

    Home | /
    About | /about
    Docs | /docs/
      Installation | /docs/install

### nav TT variable structure

`nav` is an array of hashrefs. Each item has `label`, `url`, and
`children` keys. See [Views](/docs/views) for looping examples.

If `nav.conf` is missing, `nav` is an empty array and the template
renders without navigation.

### Alternate nav file

Override the default path in `lazysite.conf`:

    nav_file: lazysite/docs-nav.conf

The path is relative to the docroot.

## Authentication

Authentication is configured through three mechanisms:

- User credentials in `lazysite/auth/users`
- Group memberships in `lazysite/auth/groups`
- Per-page `auth:` and `auth_groups:` front matter keys
- Site-wide `auth_default:` and `manager_groups:` in `lazysite.conf`

See [Authentication](/docs/auth) for full details.

## Forms

Forms are configured in three files under `lazysite/forms/`:

`FORMNAME.conf`
: Per-form configuration. Lists dispatch targets by handler ID.

`handlers.conf`
: Named dispatch handlers. Each handler has an `id`, `type`, `name`,
  and type-specific settings (e.g. `path` for file storage, `to`/`from`
  for SMTP).

`smtp.conf`
: SMTP connection settings shared by all SMTP-type handlers.

See [Forms](/docs/forms) and [Forms SMTP](/docs/forms-smtp) for full
details.

## Plugins

Plugins are CGI scripts and tools that register themselves with the
manager through a `--describe` JSON protocol. Enabled plugins appear in
the manager Plugins page.

Auto-discovery scans `cgi-bin/` and `tools/` for scripts supporting
`--describe`. Enable or disable from the manager Plugins page.

To pre-enable without the manager, list scripts in `lazysite.conf`:

    plugins:
      - cgi-bin/lazysite-auth.pl
      - cgi-bin/lazysite-form-handler.pl
      - tools/lazysite-audit.pl

## Logging

Log level and format are set in `lazysite.conf`:

    log_level: INFO    # ERROR, WARN, INFO, DEBUG
    log_format: text   # text or json

Both can be overridden at startup with environment variables:

    LAZYSITE_LOG_LEVEL=DEBUG perl tools/lazysite-server.pl ...
    LAZYSITE_LOG_FORMAT=json perl tools/lazysite-server.pl ...

## Themes

Activate a theme by name in `lazysite.conf`:

    theme: default

The processor loads `lazysite/themes/default/view.tt`. Assets in the
theme's `assets/` directory are served from the docroot's
`lazysite-assets/THEMENAME/` path when the theme declares a
`theme.json` manifest.

See [Views and themes](/docs/views) for theme installation and authoring.

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

## Config path override

The default `lazysite.conf` path can be overridden via a command-line
argument or environment variable. This is rarely needed - each site on
a server has its own docroot and therefore its own `lazysite.conf`
automatically. See
[Config path override](/docs/features/configuration/conf-path-override)
for details.

[views]: https://github.com/OpenDigitalCC/lazysite-views
[github]: https://github.com/OpenDigitalCC/lazysite
