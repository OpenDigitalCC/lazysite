---
title: Configuration
subtitle: Layouts, navigation, site variables, forms, auth, and extensions.
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
  with `lazysite channel edge|beta|stable|certified --docroot ...` (or
  `--domain <site>` / `--all`), or from Manager → Site settings. See
  [Update channel](/docs/features/configuration/update-channel).

`update_policy`
: `auto` or `manual` (default). Whether a fleet-wide `lazysite upgrade --all`
  run (deb-managed hosts) touches this site at all: `manual` sites are
  skipped and upgraded only deliberately. Set with
  `lazysite policy auto|manual --docroot ...` (audited as `policy-set`).

`log_level`
: `ERROR`, `WARN`, `INFO` (default), or `DEBUG`.

`log_format`
: `text` (default) or `json`.

`extensions`
: List of extension script paths to pre-enable without using the manager
  UI. `plugins` is the older spelling of this key and still opens the
  same list - a site keeps whichever it has, and carrying both gives one
  list rather than two that could disagree.

`auth_default`
: Site-wide default for the `auth:` front matter key. `required`,
  `optional`, or `none` (default).

`auth_header_user`, `auth_header_name`, `auth_header_email`, `auth_header_groups`
: Override HTTP header names when using an external auth proxy.
  Defaults: `X-Remote-User`, `X-Remote-Name`, `X-Remote-Email`,
  `X-Remote-Groups`.
  Every reader honours them - the page gate, the per-file ACLs, the manager
  and its API - and only under `auth_proxy_trusted: true`, from a peer listed
  in `auth_proxy_trusted_from`; behind the built-in
  cookie login the identity is the login's, whatever these are set to.

`trusted_proxies`
: The front ends whose `X-Forwarded-For` the engine believes about a visitor's
  address: addresses or CIDR ranges, comma separated; empty or absent means the
  private ranges, `none` ignores the header. It is safe only when the front end
  **appends** the client's address to the header (lazysite's nginx templates do
  since 0.15.2, SM929: `proxy_set_header X-Forwarded-For
  $proxy_add_x_forwarded_for;`). A front end that passes the client's own header
  through - a vhost rendered from an older template - lets any visitor choose
  their address, and every control keyed on it (sign-in limit, bad-URL blocker,
  form limit, address rules) takes their word. Probe it: a request with
  `X-Forwarded-For: 192.0.2.55` must not be seen as `192.0.2.55`. `lazysite
  check` warns whenever the setting is set, and the Hestia rollout reports a site
  with the setting behind an older vhost as a failure; the fix is to rebuild the
  vhost.

`manager_addresses`, `manager_addresses_deny`
: Names of address lists (Access, Address lists) that limit who may reach the
  manager and its API by the address they come from, for everyone and apart from
  any group. `manager_addresses: office` allows only the addresses in the allow
  list `office`; `manager_addresses_deny: blocked` refuses those in the deny list
  `blocked`, and deny wins. A refused visitor is told "This page is not available
  from your address." The sign-in pages are outside the manager and stay
  reachable. Comma separated; empty means any address. Set from the Config page by
  a signed-in session (a value that would shut your own address out is refused).
  The address is the visitor's, worked out with `trusted_proxies`: behind a front
  end that is not listed there every visitor looks like the proxy and the rule
  means nothing. A group can be limited the same way on the Groups page.

`signin_addresses`, `signin_addresses_deny`
: Names of address lists (Access, Address lists) that limit where a sign-in may be
  made from: this site's own sign-in and the Odoo extension's sign-in through a
  page (its password step and its authenticator-code step). `signin_addresses:
  office` allows sign-in only from the addresses in the allow list `office`;
  `signin_addresses_deny: blocked` refuses those in the deny list `blocked`, and
  deny wins. The refusal comes before the password is looked at and before the
  sign-in rate limit counts the attempt, and the visitor is told "Sign-in is not
  available from your address." Each address is recorded once an hour as
  `address-refused signin`. A session already open is untouched, and signing out
  is never refused. It is a compensating control beside a second factor, not a
  second factor. Comma separated; empty means any address. Set from the Config
  page by a signed-in session (a value that would shut your own address out of
  signing in is refused). The address is the visitor's, worked out with
  `trusted_proxies`, as for `manager_addresses`.

`auth_header_groups_separator`
: What separates the groups in the groups header. Default `,`; Authentik sends
  `|`. Each part is trimmed and an empty part dropped. One rule for every
  reader.

`auth_group_map`
: Maps a directory group name to a lazysite group name, for groups that arrive
  in the groups header from a trusted proxy. One line, comma-separated entries:
  `auth_group_map: Site Editors = editors, Platform Admins = operators`. The
  directory name is matched ignoring case and extra spaces; the target must be a
  valid group name (letters, digits, hyphen, underscore, at most 64). A name with
  no entry is normalised: lowercase, any run of other characters becomes one
  hyphen, hyphens trimmed at the ends, cut to 64 - so `Site Editors` is
  `site-editors`. A name with nothing left is dropped with a warning in the log.
  A group that arrives this way gives page and file access by name; it grants
  manager capabilities only when the operator has ticked the directory mark on
  the group's record on the Groups page. See
  [Behind an identity provider](/docs/behind-an-identity-provider).

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
extensions:
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
files, users, and extensions - with its own look: site name, theme (or
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

**Adding one (SM217).** On the Domains page, use **Add domain** and answer the
content-folder question with **"The same content as &lt;host&gt;"**, under *Share
an existing site*. That is the whole of it: the new host serves the content the
named one already serves, and the Domains list then tags the row *alias of
&lt;host&gt;* so the relationship is visible without opening anything.

Three things follow from what an alias *is*, and the engine enforces each rather
than trusting the form:

- **No content folder is created, and nothing is copied.** The alias serves the
  folder that already exists.
- **No starter page is seeded.** Seeding an alias would write into the canonical
  domain's own content, so the option is not offered.
- **You cannot give an alias a content root of its own.** A host with its own
  folder is an ordinary domain - use **Add domain** with a folder. The
  `domain-alias-add` action refuses a `content_root` and says so, rather than
  accepting it and ignoring it.
- **An alias renders from its canonical domain.** Its pages' `<link
  rel="canonical">`, and the addresses in the sitemap, `llms.txt` and the feeds
  of the shared folder, are the canonical domain's `site_url`, so search
  engines see one site. The alias still serves under its own name, with its own
  `site_url`; the canonical address is the `canonical_url` TT variable. The
  canonical domain is the one the Domains list names - the first domain
  serving that folder, the primary first. A host with no content folder of its
  own serves the primary's content and so is an alias of the primary.

Only a domain that has a **named** content folder can be shared. A host serving
the default site has no folder of its own to share; to add a second name for the
default site, add a domain and leave the folder empty.

DNS and a TLS certificate are still yours to arrange - an alias is a new host,
and this step does not touch either. The page runs its usual reachability check
afterwards and reports what it found.
- **Two hosts serving one set of files is an alias**, and
  `domain-alias-add` says so in one call: give it `host` and `alias_of`,
  and the new host is registered with the **same `content_root` as the
  host it names** - read from that host, not typed again. Adding the
  second domain by hand and copying the path also works and is where the
  mistake is: a typo in the shared path is accepted, and the new host
  then serves its own empty folder under a name that says it is the same
  site. The action takes no `content_root` of its own and refuses one.
  Presentation overrides still apply per host, so an alias may look
  different while serving the same content, and `domains-list` marks each
  row `alias_of` the first host carrying its content root - derived from
  the roots themselves, never stored, so it cannot disagree with what
  decides what is served. A host with no `content_root` reads as an alias
  of `(default)`.

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

One line per item: the label, a `|`, and the address. A child is indented
under its parent. It is the format the Navigation editor and `set_nav` write:

```
# lazysite navigation
Home | /
About | /about
Docs | /docs
  Install | /docs/install
  Authoring | /docs/authoring
Resources
  GitHub | https://github.com/example
```

Rules:

- **`Label | /url`**, split at the first `|`; spaces around either part are
  trimmed. A later `|` is part of the address.
- **A line with no `|` is a heading**: an item with no address, rendered as a
  non-clickable group label (`Resources` above).
- **A line that starts with whitespace is a child** of the nearest top-level
  line above it. One level only: a line indented further is still a child of
  that top-level item. An indented line with no top-level line above it is a
  top-level item.
- **`#` as the first non-blank character makes the line a comment.** A `#`
  later in the line is part of the label or address. Blank lines are skipped.
- A line with no label (`| /x`) is dropped.
- The file is read as UTF-8.

### Addresses

A nav address is a path (`/about`), an `http` or `https` address, `mailto:`
or `tel:` - the rule `| url_safe` applies to a link in a template. An address
whose scheme can run script or is not a web address (`javascript:`, `data:`,
`vbscript:` and the rest) is refused by the Navigation editor, `set_nav`,
`nav-save`, a WebDAV PUT of a nav file and a save of a nav file through the
file editor. One already in a nav file renders as `#` and is logged;
`lazysite validate nav.conf` and `lazysite check` name it.

### nav TT variable structure

`nav` is an array of hashrefs. Each item has `label`, `url`, and
`children` keys. See [Views](/docs/features/configuration/views) for looping examples.

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

Forms are configured in files under `lazysite/forms/`:

`FORMNAME.conf`
: Per-form configuration. Lists the handlers it calls, by ID.

`handlers.conf`
: The handlers - named functions a form or the schedule calls. Each has an
  `id`, `type` (`smtp`, `file`, `table` or `connector`), `name`, and its
  type's settings. Edited through the Handlers page, the control API, MCP or
  `lazysite-handlers.pl`, where the handler's destination decides the
  capability.

`schedule.conf`
: What the timer calls: a handler, an interval, fixed fields.

`smtp.conf`
: SMTP connection settings shared by all SMTP-type handlers.

See [Forms](/docs/forms) and [Forms SMTP](/docs/forms-smtp) for full
details.

## Extensions

Extensions are CGI scripts and tools that register themselves with the
manager through a `--describe` JSON protocol. They extend the core rather
than plug into it: the renderer requires nothing from them, and every one
ships in the package rather than being installed. Enabled extensions
appear on the Extensions page.

Auto-discovery scans `cgi-bin/` and `tools/` for scripts supporting
`--describe`. Enable or disable from the Extensions page.

To pre-enable without the manager, list scripts in `lazysite.conf`:

    extensions:
      - lazysite-auth.pl
      - plugins/form-handler.pl
      - plugins/audit.pl

## URL remapper

For a site that has **replaced another on the same hostname** while links to the
old one are still in the world - notifications, invoices, helpdesk tickets. A
rule sends a path prefix, and everything under it, to a destination you name,
keeping the rest of the path and the query string:

    /web/order?id=42   ->   https://backend.example.com/order?id=42

It answers **only when nothing else does**: a real page and an alias both win,
so a rule can cover an old link and can never shadow content. Prefixes match on
a path boundary - `/web` covers `/web` and `/web/login`, never `/website-terms`.
302 unless a rule asks for 301; a migration's destination can move, and a
cached permanent redirect to a host that later moves is a trap.

**Switch it on** on the Extensions page (it ships off). **Set a domain's
rules** with the `remap-save` action, which needs *Domains & site packages* and
replaces that one domain's rules:

    {"host": "www.example.com",
     "rules": [ {"prefix": "/web", "destination": "https://backend.example.com"},
                {"prefix": "/helpdesk", "destination": "https://backend.example.com/support", "code": 301} ]}

An empty `rules` list removes the domain's rules. `remap-list` returns them. A
manager confined to one domain may set rules for that domain only, and never
for a host that is not a registered domain.

**The destination always comes from the rules, never from the request** - there
is no `?to=`, and there will not be one, because that would make the site an
open redirect.

**When can a rule go?** *Rules and use*, on the extension's own row on the
Extensions -> Configure page, shows how often each rule was followed and when it was
last used, read from the visitor log. When the last-used date stops moving, the
links it covered have stopped arriving. If the visitor log is not recording, the
report says so rather than showing zero - "nobody followed it" and "nothing was
recorded" are different answers, and only the first means a rule can go.

## Logging

Log level and format are set in `lazysite.conf`:

    log_level: INFO    # ERROR, WARN, INFO, DEBUG
    log_format: text   # text or json

Both can be overridden at startup with environment variables:

    LAZYSITE_LOG_LEVEL=DEBUG perl tools/lazysite-server.pl ...
    LAZYSITE_LOG_FORMAT=json perl tools/lazysite-server.pl ...

To also forward log streams to syslog for an external collector (the
"Logging & forwarding" extension manages these keys):

    forward_audit: off        # audit-trail entries -> syslog, INFO priority
    forward_diagnostics:      # blank = WARN and above (the default)
    syslog_facility: daemon   # or local0..local7

Forwarding is best-effort and never blocks the site; the files under
`lazysite/logs/` remain the record.

**Diagnostics are forwarded by default, at WARN and above.** The application's
own log events go to STDERR, and whether STDERR reaches a log you can read is
decided by the web server rather than by the site - on some FastCGI arrangements
it reaches nothing at all. syslog is the second sink, so a warning the engine
raises is not lost because of how the site is fronted.

`forward_diagnostics` takes a level rather than a yes/no:

| Value | Forwards |
| --- | --- |
| *blank or absent* | WARN and above - the default |
| `off` | nothing |
| `error` / `warn` / `info` / `debug` | that level and above |
| `on` | every level |

`forward_audit` is separate, is a plain on/off, and stays **off** by default: it
copies an access record rather than a diagnostic.

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

See [Layouts and themes](/docs/ai-briefing-layouts) for installation and
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
- At most 200 files are read per scan, the first 200 in file-name order
  (then sorted), so the same pages are listed on every render. Set
  `scan_limit:` in `lazysite.conf` to change it. A capped scan logs a warning.
- `NAME_total` beside the list counts the pages the pattern matched that the
  reader may see, before `filter=` and before the cap, so a page can say
  `showing [% posts.size %] of [% posts_total %]`
- `limit=N` and `offset=N` page the list after `filter=` and `sort=`:
  `scan:/blog/*.md sort=date desc offset=10 limit=10` is the second ten.
  `limit=` is capped by `scan_limit`, and `offset=` reaches no further than
  the pages the scan read, so raise `scan_limit` to page a longer list.
  `NAME_total` is not changed by them. A value that is not a whole number is
  ignored and logged.
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
