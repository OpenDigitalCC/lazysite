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
  template filenames in `lazysite/templates/registries/` without the
  `.tt` extension.

`tt_page_var`
: Page-scoped TT variables. Supports `url:`, `scan:`, `${ENV}`, and
  literal values. Page variables override site variables of the same name.

`raw`
: Set `raw: true` to output converted content without the view template
  wrapper. Default content type: `text/plain; charset=utf-8`.

`api`
: Set `api: true` for pure TT output with no Markdown conversion and no
  layout. Default content type: `application/json; charset=utf-8`.

`content_type`
: Custom `Content-type` header. Used with `raw: true` or `api: true`.
  Example: `content_type: text/html; charset=utf-8`

`date`
: Publication date in `YYYY-MM-DD` format. Used in feed entries. Falls
  back to file mtime if not set.

`layout`
: Named view template for this page. Checks `lazysite/themes/NAME/view.tt`
  then `lazysite/templates/NAME.tt`. Falls back to default `view.tt`.

`query_params`
: List of accepted URL query parameter names. Declared parameters are
  available as `[% query.param_name %]`. Requests with matching parameters
  bypass the cache.

`tags`
: Tags for page scan results. YAML list, comma-separated, or single value.

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

### Special keys

`theme`
: Site-wide view template name or remote URL.

`nav_file`
: Navigation file path, docroot-relative. Default: `lazysite/nav.conf`.

All other keys are available as TT variables in page content and the
view template.

See [Configuration](/docs/configuration) for full details.

## TT variables

### Automatic variables (always available)

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

`nav`
: Navigation array from `nav.conf`. Each item has `label`, `url`,
  `children` (array of `label`/`url` hashes).

`query`
: Query parameter hash. Only populated when `query_params:` is declared
  in front matter.

`theme_assets`
: Asset path for remote themes. Set automatically when a remote layout
  is in use.

### Variable precedence

Site variables (from `lazysite.conf`) are loaded first. Page variables
(from `tt_page_var`) override site variables of the same name. Automatic
variables (`page_title`, `page_subtitle`, `content`) override both.

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

    public_html/
      lazysite/
        lazysite.conf              <- site configuration
        nav.conf                   <- navigation
        templates/
          view.tt                  <- default view template
          registries/              <- registry templates (.tt)
        themes/
          NAME/view.tt             <- named themes
        cache/
          layouts/                 <- remote layout cache
          ct/                      <- content type cache
      cgi-bin/
        lazysite-processor.pl      <- processor

    Source files:
      *.md                         <- Markdown pages
      *.url                        <- remote page pointers
      *.html                       <- generated cache (auto-created)

    Registry output:
      sitemap.xml                  <- generated from sitemap.xml.tt
      llms.txt                     <- generated from llms.txt.tt
      feed.rss                     <- generated from feed.rss.tt
      feed.atom                    <- generated from feed.atom.tt
