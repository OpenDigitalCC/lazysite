---
title: Reference
subtitle: Front matter keys, TT variables, configuration keys, and file locations.
register:
  - sitemap.xml
---

## Front matter keys

Front matter is the YAML metadata block at the top of each page. Its keys
are documented, with examples, in [Front matter](/docs/frontmatter).

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
: `key: scan:/path/*.md sort=field dir limit=N offset=N` - returns array of
  page objects, at most `scan_limit` of them (`limit=` and `offset=` page the
  sorted list, `limit=` capped by `scan_limit`), and `key_total`, the number the pattern
  matched that the reader may see.

### Recognised keys

`site_name`
: Site name. Used in the layout template title and header.

`site_url`
: Site URL. Typically `${REQUEST_SCHEME}://${SERVER_NAME}` so the same
  config works on staging and production.

`layout`
: Active layout name. The processor resolves it to
  `lazysite/layouts/NAME/layout.tt`. May also be a remote URL.

`theme`
: Active theme name. The processor resolves it to
  `lazysite/layouts/LAYOUT/themes/THEME/theme.json`. The theme's
  `layouts[]` array must contain the active layout or the theme is
  skipped with a warning.

`layouts_repo`
: GitHub OWNER/REPO path for the manager's "Install from Releases"
  theme browser. Default unset hides the browser.

`nav_file`
: Navigation file path, docroot-relative. Default: `lazysite/nav.conf`.

`scan_limit`
: How many pages a `scan:` reads, the first in file-name order. Default
  200. A scan that reaches more logs a warning; its `_total` says how many.
  The ceiling for a directive's `limit=`.

`csp`
: The Content-Security-Policy mode: `report-only` (the default, and what any
  unrecognised value reads as), `enforce`, or `off`. The manager is never
  enforced.

`app_name`, `app_short_name`, `app_scope`, `app_start_url`, `app_theme_colour`, `app_background_colour`, `app_icon_64`, `app_icon_192`, `app_icon_512`, `app_icon_maskable`, `app_shell`
: Install the site, or the section under `app_scope`, as an app: the engine
  generates the web app manifest and the service worker from these. Setting
  `app_name` turns it on. See [Installing a site as an app](/docs/app).

`csp_script_src`, `csp_connect_src`, `csp_img_src`, `csp_frame_src`
: Hosts a page may load from beyond its own, each list appended to the
  default for that directive: `csp_script_src: https://ads.example.com,
  https://*.cdn.example.com`. Each entry is an https origin - `https://host` or
  `https://host:port`, a leading `*.` for subdomains - and nothing else: no bare
  `*`, no path, no `'unsafe-...'` or other keyword. An entry that is not an
  origin is left out of the policy and logged, and `lazysite check` names it.
  On an instance serving several domains, `alias.<host>.csp_script_src:` (and
  the others) gives a domain its own list in place of the site's. The manager's
  pages carry none of them.

`search_default`
: Site-wide default for the `search:` front matter key. Set to `true`
  (default) or `false`. Pages without an explicit `search:` key inherit
  this value.

`manager`
: `enabled` or `disabled`. Controls the built-in manager UI at
  `/manager`.

`manager_path`
: URL path for the manager. Default: `/manager`.

`manager_groups` *(retired - SM138)*
: Retired. Manager access is the `ui` capability granted to a group (Groups
  page); on upgrade any group this key named receives its capabilities and the
  line is removed.

`update_channel`
: The minimum release maturity accepted on upgrade, on the
  `edge < beta < stable < certified` ladder: `stable` takes supported
  releases; `certified` takes only builds whose compliance records were
  walked (ADR 0010),
  `beta` takes beta and stable, any other value (default) accepts every
  release. Out-of-channel upgrades are skipped and audited. See
  [Update channel](/docs/features/configuration/update-channel).

`update_policy`
: `auto` or `manual` (default). Whether the fleet-wide
  `lazysite upgrade --all` run on deb-managed hosts upgrades this site;
  `manual` sites are skipped. Set with `lazysite policy auto|manual`.

`log_level`
: One of `ERROR`, `WARN`, `INFO`, `DEBUG`. Default: `INFO`.

`log_format`
: `text` (default) or `json`.

`extensions`
: List of extension script paths to pre-enable without going through the
  manager.

`auth_default`
: Site-wide default for the `auth:` front matter key. Set to `required`,
  `optional`, or `none` (default).

`auth_header_user`, `auth_header_name`, `auth_header_email`, `auth_header_groups`
: Override the HTTP headers used by an external auth proxy. Defaults:
  `X-Remote-User`, `X-Remote-Name`, `X-Remote-Email`, `X-Remote-Groups`.

`alias_hosts`
: Comma-separated list of domain-alias hostnames that serve this site
  with their own presentation. Requests from other hosts (and the
  primary) get the base configuration.

`alias.<host>.<key>`
: Per-alias-host override. `<key>` is limited to `site_name`, `theme`,
  `layout`, `nav_file`, `search_default`; other keys are ignored.
  Each alias host has its own page-cache slot (`lazysite/cache/hosts/`),
  cleared alongside the primary cache. Conf-file only - not settable via
  the manager or API.

All other keys are available as TT variables in page content and the
layout template.

See [Configuration](/docs/configuration) for full details.

## TT variables

### Automatic variables (always available in layout.tt)

`page_title`
: From front matter `title:`.

`page_subtitle`
: From front matter `subtitle:`.

`page_modified`
: Human-readable file mtime, e.g. "3 April 2026".

`page_modified_iso`
: ISO 8601 file mtime, e.g. "2026-04-03".

`content`
: Rendered page body HTML. Available in the layout template.

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

`alias_host`
: The active domain-alias host (e.g. `brand2.example`) when the request's
  Host header matches a declared `alias_hosts` entry; empty string on the
  primary host. Useful for per-host branching.

`canonical_url`
: The `site_url` of the domain this host is an alias of (one serving the same
  content folder, listed before it), or this host's own `site_url`. The engine's
  canonical link and the registries use it; a layout that writes its own
  canonical link should too.

`layout_name`
: Active layout name, as sanitised by the processor.

`theme`
: Parsed `theme.json` (hash) when a compatible theme is active. Access
  config values as `[% theme.config.GROUP.KEY %]`. Empty hash when no
  theme is active.

`theme_name`
: Active theme name. Unset when no compatible theme is active.

`theme_assets`
: URL prefix for active-theme assets.
  `/lazysite-assets/LAYOUT/THEME/` for local themes (nested per D013);
  `/lazysite-assets/CACHE_KEY/` for remote layouts (flat).
  Unset when no theme is active.

`theme_css`
: Pre-rendered `<style>:root { ... }` block of CSS custom properties
  derived from `theme.config`. Empty string when no theme is active.
  Naming convention: `--theme-GROUP-KEY`.

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
: `1` if the authenticated user has manager access (a group grants the `ui`
  capability), `0` otherwise. Use in layouts to gate admin UI.

`visitor.in_list('NAME')`, `visitor.in_any(['A', 'B'])`
: `1` when the visitor's address is on the named address list (or on any of the
  lists), `0` otherwise, including when no such list exists. It answers
  membership only: no variable holds the address. A page, include or layout
  that calls it is rendered for each request, never kept in the page cache, and
  sent `Cache-Control: no-store, private`. The address is the one `trusted_proxies`
  works out, so behind a front end name it there. See
  [Showing the visitor's IP](/docs/features/authoring/visitor-ip#asking-whether-the-address-is-on-a-list).

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
        layouts/
          NAME/layout.tt           <- layout template
          NAME/layout.json         <- layout metadata (optional)
          NAME/themes/THEME/
            theme.json             <- theme manifest
            main.css               <- theme-scoped CSS
            assets/                <- theme assets (images, fonts)
        manager/
          layout.tt                <- manager UI chrome (internal)
          assets/manager.css       <- manager CSS source
        templates/
          registries/              <- registry templates (.tt)
        auth/
          users                    <- user credentials
          groups                   <- group memberships
        forms/
          FORMNAME.conf            <- per-form target config
          handlers.conf            <- the handlers a form or the schedule calls
          schedule.conf            <- what the timer calls
          smtp.conf                <- SMTP connection settings
        cache/
          layouts/                 <- remote-layout cache
          tt/                      <- TT compile cache
        logs/                      <- log files
      lazysite-assets/
        LAYOUT/THEME/              <- web-served theme assets (nested)
      manager/
        assets/
          manager.css              <- manager CSS (mirrored from source)
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
