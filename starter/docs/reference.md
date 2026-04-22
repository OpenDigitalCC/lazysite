---
title: Reference
subtitle: Front matter keys, TT variables, configuration keys, and file locations.
register:
  - sitemap.xml
  - llms.txt
---

## Front matter keys

All keys are optional unless noted.

`title`
: Page title. Used in the `<title>` tag and page header. Required for
  most pages.

`subtitle`
: Short description shown below the title.

`ttl`
: Cache TTL in seconds. The page regenerates after this interval rather
  than on `.md` file edit. Example: `ttl: 300`

`register`
: List of registry files this page should appear in. Values match
  template filenames under `lazysite/templates/registries/` without
  the `.tt` extension. Common values: `sitemap.xml`, `llms.txt`,
  `feed.rss`, `feed.atom`.

`tt_page_var`
: Page-scoped Template Toolkit variables. Supports `url:`, `scan:`,
  `${ENV}`, and literal values. Page variables override site variables
  of the same name.

`raw`
: Set `raw: true` to output the converted content body without the view
  template wrapper. TT variables still resolve. Useful for content
  fragments, AJAX partials, or API-style endpoints.

`api`
: Set `api: true` to serve the rendered content as an API endpoint.
  Default content type: `application/json; charset=utf-8`. Combine with
  `tt_page_var` (especially `scan:`) and `query_params` for dynamic JSON.

`content_type`
: Custom `Content-type` header. Used with `raw: true` or `api: true`.
  Example: `content_type: text/html; charset=utf-8`

`date`
: Publication date in `YYYY-MM-DD` format. Used in feed entries. Falls
  back to file mtime if not set.

`layout`
: Named view template for this page. The processor checks
  `lazysite/themes/NAME/view.tt` first, then falls back to the default
  theme.

`auth`
: Authentication requirement. Values: `required`, `optional`, `none`
  (default). See [Authentication](/docs/auth).

`auth_groups`
: List of group names. User must be authenticated AND in at least one
  listed group to view the page.

`payment`
: Payment requirement for the x402 payment flow. See [Payment](/docs/payment).

`query_params`
: List of accepted URL query parameter names. Declared parameters are
  available as `[% query.param_name %]`. Requests with matching parameters
  bypass the cache.

`tags`
: Tags for page scan results. YAML list, comma-separated, or single value.

`search`
: Set `search: true` or `search: false` to control whether the page
  appears in the search index. Defaults to the site-wide `search_default`
  setting.

`form`
: Enables form processing for the page and names the form. Name must be
  alphanumeric with hyphens and underscores. A matching
  `lazysite/forms/NAME.conf` must exist. See [Forms](/docs/forms).

See [Authoring](/docs/authoring) for full usage details and examples.

## lazysite.conf keys

Site-wide configuration in `public_html/lazysite/lazysite.conf`. One
key-value pair per line.

### Value types

Literal string
: `key: value` - used as-is.

Environment variable
: `key: ${ENV_VAR}` - interpolated from the CGI environment. Multiple
  vars and mixed text supported: `${REQUEST_SCHEME}://${SERVER_NAME}`

Remote URL
: `key: url:https://...` - fetched, trimmed, and cached with the page.

Directory scan
: `key: scan:/path/*.md sort=field dir` - returns array of page objects.

### Recognised keys

`site_name`
: Site name. Used in the view template title and header.

`site_url`
: Site URL. Typically `${REQUEST_SCHEME}://${SERVER_NAME}` so the same
  config works on staging and production.

`theme`
: Active theme name. The processor loads
  `lazysite/themes/NAME/view.tt`. May also be a remote URL.

`nav_file`
: Navigation file path, docroot-relative. Default: `lazysite/nav.conf`.

`search_default`
: Site-wide default for the `search:` front matter key. Set to `true`
  (default) or `false`. Pages without an explicit `search:` key inherit
  this value.

`manager`
: `enabled` or `disabled`. Controls the built-in manager UI at
  `/manager`.

`manager_path`
: URL path for the manager. Default: `/manager`.

`manager_groups`
: Comma-separated group names. Only users in one of these groups can
  access the manager.

`log_level`
: One of `ERROR`, `WARN`, `INFO`, `DEBUG`. Default: `INFO`.

`log_format`
: `text` (default) or `json`.

`plugins`
: List of plugin script paths to pre-enable without going through the
  manager.

`auth_default`
: Site-wide default for the `auth:` front matter key. Set to `required`,
  `optional`, or `none` (default).

`auth_header_user`, `auth_header_name`, `auth_header_email`, `auth_header_groups`
: Override the HTTP headers used by an external auth proxy. Defaults:
  `X-Remote-User`, `X-Remote-Name`, `X-Remote-Email`, `X-Remote-Groups`.

All other keys are available as TT variables in page content and the
view template.

See [Configuration](/docs/configuration) for full details.

## TT variables

### Automatic variables (always available in view.tt)

`page_title`
: From front matter `title:`.

`page_subtitle`
: From front matter `subtitle:`.

`page_modified`
: Human-readable file mtime, e.g. "3 April 2026".

`page_modified_iso`
: ISO 8601 file mtime, e.g. "2026-04-03".

`content`
: Rendered page body HTML. Available in the view template.

`request_uri`
: Current request path, e.g. `/about`. Set from `REDIRECT_URL` or
  `REQUEST_URI`.

`page_source`
: Docroot-relative path of the source `.md` file, e.g. `/about.md`.
  Useful for admin bar and edit links.

`nav`
: Navigation array from `nav.conf`. Each item has `label`, `url`,
  `children` (array of `label`/`url` hashes).

`query`, `params`
: Query parameter hash. Only populated when `query_params:` is declared
  in front matter. `params` is an alias for `query`.

`year`
: Current year as a 4-digit string, e.g. `2026`.

`search_enabled`
: `1` if a `search-results.md` (or `.url`) page exists in the docroot,
  `0` otherwise.

`site_name`, `site_url`
: From `lazysite.conf`.

`theme`
: Active theme name.

`theme_assets`
: Asset path for remote themes. Set to `/lazysite-assets/NAME` when a
  remote theme is in use. Not set for local themes.

### Auth variables

`authenticated`
: `1` if the request carries valid auth headers, `0` otherwise.

`auth_user`
: Username, or empty string if not authenticated.

`auth_name`
: Display name from the proxy header (or built-in auth). May be empty.

`auth_email`
: Email address from the proxy header. May be empty.

`auth_groups`
: Array of group names the user belongs to.

`editor`
: `1` if the authenticated user is in `manager_groups` (i.e. has
  manager access), `0` otherwise. Use in views to gate admin UI.

### Variable precedence

Site variables (from `lazysite.conf`) are loaded first. Page variables
(from `tt_page_var`) override site variables of the same name. Automatic
variables (`page_title`, `page_subtitle`, `content`, etc.) override both.

## Environment variable allowlist

Only these CGI variables may be interpolated via `${VAR}` in
`lazysite.conf`:

- `SERVER_NAME` - server hostname
- `SERVER_PORT` - server port
- `REQUEST_SCHEME` - `http` or `https`
- `HTTPS` - `on` if HTTPS
- `REQUEST_URI` - full request URI
- `REDIRECT_URL` - requested page path (e.g. `/about`)
- `DOCUMENT_ROOT` - filesystem docroot path
- `SERVER_ADMIN` - server admin email

`HTTP_HOST` is intentionally excluded - it is request-supplied and
untrusted. Use `SERVER_NAME` for host-based URL construction.

## Security

### Path traversal

`sanitise_uri` rejects null bytes, `..` path segments, and suspicious
characters before constructing filesystem paths. After construction, each
path is verified with `realpath` to confirm it resolves within `$DOCROOT`.
Symlinks pointing outside the docroot are rejected.

The same check is applied inside `write_html` before any file is written,
guarding against symlink-based overwrite attacks on the cache output path.

### Template Toolkit injection

All values extracted from YAML front matter - including `title`, `subtitle`,
and `tt_page_var` entries - have TT directive markers (`[%` and `%]`) stripped
before entering the template context. `register` list items are stripped at
parse time. This prevents authored content from injecting TT directives into
the rendering pipeline.

### Fenced div class names

The class name following `:::` is validated against `/\A[\w][\w-]*\z/` before
use. Blocks with class names containing characters outside word characters and
hyphens are rejected - the content renders without a wrapper div and a warning
is written to the error log.

### oEmbed JSON parsing

oEmbed provider responses are parsed with `JSON::PP` (Perl core module) rather
than regex extraction. The `html` field from the parsed response is injected
into the page. Provider responses are trusted as-is - restrict `%OEMBED_PROVIDERS`
in `lazysite-processor.pl` to known hosts if untrusted providers are a concern in
your deployment.

## File locations

    DOCROOT/
      lazysite/
        lazysite.conf              <- site configuration
        nav.conf                   <- navigation
        themes/
          NAME/view.tt             <- theme template (per theme)
          NAME/assets/             <- theme assets
          manager/view.tt          <- manager chrome (system theme)
        templates/
          registries/              <- registry templates (.tt)
        auth/
          users                    <- user credentials
          groups                   <- group memberships
        forms/
          FORMNAME.conf            <- per-form target config
          handlers.conf            <- named dispatch handlers
          smtp.conf                <- SMTP connection settings
        cache/                     <- HTML cache, plugin cache
        logs/                      <- log files
      manager/
        assets/
          manager.css              <- manager CSS
          cm/                      <- CodeMirror assets
      404.md
      index.md
      [content pages]

    Scripts (repo root, copied to site by the installer):
      lazysite-processor.pl        <- main processor
      lazysite-auth.pl             <- built-in auth
      plugins/form-handler.pl     <- form dispatch
      plugins/form-smtp.pl        <- SMTP helper
      lazysite-manager-api.pl      <- manager JSON API
      plugins/payment-demo.pl     <- payment demo helper

    Source files:
      *.md                         <- Markdown pages
      *.url                        <- remote page pointers
      *.html                       <- generated cache (auto-created)

    Registry output (generated at DOCROOT):
      sitemap.xml                  <- generated from sitemap.xml.tt
      llms.txt                     <- generated from llms.txt.tt
      feed.rss                     <- generated from feed.rss.tt
      feed.atom                    <- generated from feed.atom.tt
