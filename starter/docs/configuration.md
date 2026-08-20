---
title: Configuration
subtitle: Layouts, navigation, site variables, forms, auth, and plugins.
register:
  - sitemap.xml
---

lazysite can be configured two ways. The **[manager](/docs/manager)** is a menu-driven web interface - the easiest way to change most settings, with nothing to edit by hand. This page covers the other way: the **configuration files** themselves, which is what the manager writes to underneath. Systems and AI agents can also configure a site over the [control API](/docs/api) and the [AI connector (MCP)](/docs/ai-connector-setup).
## lazysite.conf

`lazysite/lazysite.conf` defines site-wide variables available in
`layout.tt` and all page bodies. It is a plain text file with one
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

`layout`
: Active layout. The processor resolves it to
  `lazysite/layouts/NAME/layout.tt`. May also be a full remote URL.

`theme`
: Active theme. Must declare the active layout in its
  `theme.json`'s `layouts[]`. The processor resolves it to
  `lazysite/layouts/LAYOUT/themes/THEME/theme.json`.

`layouts_repo`
: GitHub OWNER/REPO source for the manager's release browser.
  Default unset hides the browser.

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

`manager_groups` *(retired - SM138)*
: Retired. Manager access is the `ui` capability granted through a group on
  the Groups page; on upgrade any group this key named receives its
  capabilities explicitly and the line is removed.

`update_channel`
: The minimum release maturity the site accepts on upgrade, on the
  `edge < beta < stable < certified` ladder: `stable` installs supported
  releases; `certified` only builds whose compliance records were walked,
  `beta` takes beta and stable builds, any other value (the default)
  accepts everything. Out-of-channel upgrades are skipped and audited. Set
  with `install.pl --channel edge|beta|stable|certified --docroot ...` or from
  Manager → Site settings. See
  [Update channel](/docs/features/configuration/update-channel).

`update_policy`
: `auto` or `manual` (default). Whether a fleet-wide `lazysite upgrade --all`
  run (deb-managed hosts) touches this site at all: `manual` sites are
  skipped and upgraded only deliberately. Set with
  `install.pl --policy auto|manual --docroot ...` (audited as `policy-set`).

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

`webdav_enabled`
: `true` or `false` (default). Master switch for the `/dav` WebDAV
  publishing endpoint. While off, `/dav` returns 404. See
  [WebDAV publishing](/docs/features/configuration/webdav).

`dav_allow_insecure`
: `true` or `false` (default). Permit WebDAV Basic auth without HTTPS
  (for a TLS-terminating proxy or trusted LAN). Loopback is always
  allowed; leave off otherwise.

`alias_hosts`
: Comma-separated list of extra hostnames that serve this site as
  domain aliases, e.g. `alias_hosts: blog.example.com, brand2.example`.
  See [Domain aliases](#domain-aliases) below.

`alias.<host>.<key>`
: Per-alias-host override for a whitelisted presentation key. See
  [Domain aliases](#domain-aliases) below.

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
plugins:
  - lazysite-auth.pl
  - plugins/form-handler.pl
```

### Allowlisted environment variables

Only these CGI variables may be used with `${VAR}` syntax:
`SERVER_NAME`, `REQUEST_SCHEME`, `SERVER_PORT`, `HTTPS`, `REDIRECT_URL`,
`DOCUMENT_ROOT`, `SERVER_ADMIN`.

`HTTP_HOST` is intentionally excluded - it is request-supplied and
therefore untrusted. Use `SERVER_NAME` for host-based URL construction.

### Domain aliases

A domain alias is an additional host that serves the *same* site - same
files, users, and plugins - with its own look: site name, theme (or
layout), and navigation. Declare the hosts, then override per host:

    alias_hosts: brand2.example, blog.example.com
    alias.brand2.example.site_name: Brand Two
    alias.brand2.example.theme: dark
    alias.brand2.example.nav_file: lazysite/brand2-nav.conf

Rules:

- Only whitelisted keys may be overridden per host: `site_name`, `theme`,
  `layout`, `nav_file`, `search_default`, `content_root`, `site_url`,
  `lang`, `lang_group`. Anything else (notably `manager`, `auth_*`,
  `webdav_*`) is ignored with a logged warning - the Host header is
  request-supplied, so security settings must never vary by host.
- The request's Host header is matched case-insensitively against
  `alias_hosts` (port stripped). The primary host, undeclared hosts, and
  malformed Host headers all get the base configuration unchanged.
- The page cache is host-keyed: the primary host caches as usual, and
  each alias host caches its renders in its own slot (under
  `lazysite/cache/hosts/`), so a themed render is never served to the
  wrong host. Editing a page - or invalidating it from the manager's
  Cache page - clears every host's copy.
- The active alias host is available to layouts as the `alias_host` TT
  variable (empty on the primary), e.g. to mark canonical links.
- Domains are managed from the manager's **Domains** page or the control
  API (add, configure, remove, and per-domain access). The language keys
  (`lang`, `lang_group`) are set in the conf or via the `domain-set`
  control-API action.

The web server must route the alias hosts to the same docroot (an
Apache/nginx server alias). Registering the domain in lazysite is only the
lazysite half; DNS, the server alias and TLS are a precondition handled
outside lazysite (your control panel / Hestia).

### Multilingual language sets

A multilingual site is a *set* of hosts - one per language - linked by a
shared `lang_group`. Each language is a first-class domain with its **own
content root**, so the languages are authored and served independently under
their own hosts.

    lang: en
    lang_group: providers
    content_root: sites/en

    alias_hosts: fr.example.com, th.example.com
    alias.fr.example.com.lang: fr
    alias.fr.example.com.lang_group: providers
    alias.fr.example.com.content_root: sites/fr
    alias.th.example.com.lang: th
    alias.th.example.com.lang_group: providers
    alias.th.example.com.content_root: sites/th

- `lang` sets a host's language - emitted as `<html lang>` and the
  `Content-Language` header; a page may override it in front matter with
  `lang:`. On its own it is useful for any single-language non-English site.
- `lang_group` joins two or more hosts into a *set*. The engine then hands
  every layout a `languages` variable (each sibling's URL for the current
  page, which one is current, and whether that translation exists yet), and
  the built-in layout renders a language switcher plus `hreflang` alternates.
  Per-domain sitemaps gain `hreflang` alternates too.

Adding a new language is an **operator + DNS** act - not something an agent
can do on its own:

1. Point DNS (and TLS) for the new host at this server and add the
   web-server server-alias. This is **outside lazysite** (control panel /
   Hestia; a wildcard record + certificate covers every sub-domain at once).
2. Register the host as a domain with its **own** `content_root` (a new
   folder - the Domains page or `lazysite-domains add`), and set its `lang`
   plus the shared `lang_group`.
3. Populate that content root: copy the source language's files to the same
   paths and translate the *values* (never the keys, paths, or structure).
   The `lang-status` control-API action reports what is missing or stale per
   language, so a re-run translates exactly the gap.

A content-capable AI agent can do step 3 (the translation) on its own; steps
1-2 need the operator, because DNS and domain registration sit outside the
translation surface.

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
- Group memberships in `lazysite/auth/groups`; group capabilities (channel x
  action, incl. manager access via `ui`) in `lazysite/auth/groups-settings.json`
- Per-page `auth:` and `auth_groups:` front matter keys
- Site-wide `auth_default:` in `lazysite.conf`

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
      - lazysite-auth.pl
      - plugins/form-handler.pl
      - plugins/audit.pl

## Logging

Log level and format are set in `lazysite.conf`:

    log_level: INFO    # ERROR, WARN, INFO, DEBUG
    log_format: text   # text or json

Both can be overridden at startup with environment variables:

    LAZYSITE_LOG_LEVEL=DEBUG perl tools/lazysite-server.pl ...
    LAZYSITE_LOG_FORMAT=json perl tools/lazysite-server.pl ...

To also forward log streams to syslog for an external collector (the
"Logging & forwarding" plugin manages these keys):

    forward_audit: off        # audit-trail entries -> syslog, INFO priority
    forward_diagnostics: off  # application log events -> mapped priority
    syslog_facility: daemon   # or local0..local7

Forwarding is best-effort and never blocks the site; the files under
`lazysite/logs/` remain the record.

## Layouts and themes

Activate a layout and theme by name in `lazysite.conf`:

    layout: default
    theme: odcc

The processor resolves the layout to
`lazysite/layouts/default/layout.tt` and the theme to
`lazysite/layouts/default/themes/odcc/theme.json`. Theme assets
are web-served from `/lazysite-assets/default/odcc/` (nested).

A theme must declare the active layout in its `theme.json`'s
`layouts[]` array; mismatched themes render layout-only with a
warning.

See [Layouts and themes](/docs/views) for installation and
authoring.

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
- Recursive scanning with `**`: `scan:/gallery/**/*.md` walks subdirectories
- Maximum 200 files per scan
- Each result is realpath-checked - rejected if outside docroot

### Page object fields

Each item in the returned array carries these built-in fields:

- `url` - extensionless URI, e.g. `/blog/first-post`
- `title` - from front matter `title:`
- `subtitle` - from front matter `subtitle:` (may be empty)
- `date` - from front matter `date:`, falls back to file mtime
- `tags` - arrayref from front matter `tags:`
- `excerpt` / `searchable` - body excerpt and the page's search flag
- `path` - absolute filesystem path (useful for debugging)

**Custom keys pass through.** Any other (non-control) front-matter key is exposed
on the page object under the same name, so a registry card can be
self-describing:

    # /gallery/nova.md
    title: NOVA
    kind: Statement
    demo: /nova
    accent: "#7C5CFF"
    order: 2

    [% FOREACH t IN gallery %][% t.kind %] - [% t.demo %] - [% t.accent %][% END %]

Surrounding quotes are stripped (so `accent: "#7C5CFF"` yields `#7C5CFF` - quote a
value that starts with `#`, since a bare `# …` is a YAML comment), and TT markers
are stripped for safety. Control keys (`layout`, `theme`, `auth`, `register`,
`search`, `tt_*`) are not passed through.

### Sort order

Default sort is by filename. Use the `sort=` modifier to sort by field:

    blog_pages: scan:/blog/*.md sort=date desc
    gallery:    scan:/gallery/**/*.md sort=order asc

Built-in sort fields are `date`, `title`, `filename`; **any custom key also
sorts** (e.g. `sort=order`), and numeric values compare numerically (2 before
10), not lexically. Direction: `asc` or `desc` (default `asc`).

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

[views]: https://github.com/OpenDigitalCC/lazysite-layouts
[github]: https://github.com/OpenDigitalCC/lazysite
