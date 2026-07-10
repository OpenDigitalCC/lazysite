# SM110 - Domain aliases: one site, many hosts, different chrome

Status: BUILT phases 1 and 2, 2026-07-10. Host-matched conf overlay
(whitelisted keys), `alias_host` TT var, and the host-keyed page cache
(phase 2 - each alias host caches in its own slot; phase 1's interim
NOCACHE is retired). Tests: `t/integration/16-domain-aliases.t`.
Phase 3+ below remains open.
Driver: an operator wants an additional host to serve the *same* lazysite
site - same files, users, plugins, backend - but rendered differently: its
own site name, theme (or layout), and navigation. Distinct from multi-site
(separate docroots): here it is one docroot and only *what is rendered*
differs. A blog host and a main host share assets and management while
looking and behaving differently.

## Model

One docroot, one `lazysite.conf`. The conf declares which extra hosts are
aliases and, per host, a small set of presentation overrides. On each
request the processor sanitises the `Host` header and, when it matches a
declared alias, overlays that host's overrides onto the base configuration
before anything renders. The primary host, any undeclared host, and any
malformed `Host` header all get the base conf - zero behaviour change when
`alias_hosts` is unset.

## Configuration reference

The conf file stays flat `key: value`; aliases add two key shapes:

`alias_hosts`
: Comma-separated list of alias hostnames
  (`alias_hosts: blog.example.com, brand2.example`). A host must be listed
  here for any of its overrides to take effect.

`alias.<host>.<key>`
: Per-host override, e.g. `alias.brand2.example.site_name: Brand Two`.
  `<key>` must be on the override whitelist: `site_name`, `theme`,
  `layout`, `nav_file`, `search_default`. Any other key is ignored with a
  WARN in the log. Values go through the normal conf value resolution
  (literals, `${VAR}`, `url:`, `scan:`), the same as base keys.

The dotted alias keys are invisible to the base conf parse (`\w+` keys
only), so they can never pollute the primary host's variables, the manager
API's `config-read` subset, or the plugin descriptor's `config_keys` - all
of which see only word-shaped keys. Aliases are operator conf-file
territory in phase 1: deliberately not listed in or settable through the
manager UI / control API (`config-set` has its own narrow allowlist that
excludes them).

## Host resolution

The request host comes from `HTTP_HOST`, sanitised before matching:
lowercased, `:port` stripped, trailing dot dropped, validated against the
DNS hostname alphabet (max 253 chars). Anything malformed resolves to "no
alias" and the base conf renders. Matching happens inside
`resolve_site_vars()` - the single memoised per-request conf resolution -
so every consumer (rendering, nav parsing, layout/theme selection) sees one
consistent view; under FastCGI the memo resets per request as usual.

`nav_file` overrides resolve before nav parsing, so an alias host can carry
an entirely different navigation, or fall back to the site default when not
overridden.

## Security: why a whitelist

`Host` is request-supplied. Whatever the header selects must never weaken
policy, so the overridable keys are presentation-only. Security-relevant
keys - `manager`, `manager_path`, `auth_*`, `webdav_*`, `update_*`,
`log_*`, `plugins` - are NOT overridable per host: were they, any client
could pick its own security policy simply by sending a matching `Host`
header (e.g. enable the manager or relax the auth default on a host the
operator declared for cosmetic reasons). The worst a hostile `Host` header
can do today is select a rendering the operator explicitly configured for
that host.

`HTTP_HOST` also stays excluded from `${VAR}` conf interpolation
(`%ENV_ALLOWLIST`): the sanitised value is only *compared* against the
operator-declared list, never emitted into output.

## The cache design (phase 2 - host-keyed slots)

The primary host's page cache is a sibling `.html` next to its `.md`, with
no host in the key - host-blind. A render themed for an alias host must
never be served to the primary host or vice versa, so phase 2 made the
cache host-keyed:

Primary host
: sibling `.html` files, exactly as before SM110. Zero change.

Alias host
: reads and writes its cached render at
  `lazysite/cache/hosts/<host>/<rel>.html`, mirroring the page's
  docroot-relative path under a per-host root. The sanitised host from
  `_request_host()` is filesystem-safe by construction (DNS labels only -
  no `/`, no `..`, no leading dot), so it is used directly as one path
  segment. All other gating (protected / NOCACHE / TTL / query-carrying)
  is host-agnostic: an alias host gets exactly the caching rules the
  primary has, just in its own slots. The hosts tree lives inside
  `lazysite/cache`, so it is never web-served (the `/lazysite/` request
  block) and is excluded from backups like every regenerable cache. The
  SM133 legacy static-HTML fallback keeps checking the SIBLING path -
  a legacy page is authored content shared by every host, not a render.

Phase 1 shipped an interim NOCACHE instead: alias-host requests were
simply never cached - the smallest correct step (exclusion cannot serve a
stale or cross-host page), affordable under the SM142 FCGI pools where a
fresh render is milliseconds. It paid a render per alias request and was
replaced by the host-keyed cache in the same release, once the
invalidation story below was made exhaustive.

Invalidation (exhaustive by construction)
: a stale alias cache after an edit is worse than the render cost ever
  was, so every surface that removes or overwrites a cached sibling also
  drops the per-host copies - via `Lazysite::Util::unlink_host_copies`
  (per page) / `Lazysite::Util::clear_host_cache` (wholesale) for the
  lib-based surfaces, and inline equivalents in the standalone scripts.
  Per-page removal: editor save, delete, move (old and new path),
  migrate-url-to-local, file-upload overwrite, WebDAV write/delete/move,
  manager/MCP `cache-invalidate <page>`, installer upgrade removals, and
  the audit plugin's report refresh. Wholesale hosts-tree removal (where
  a sweep already clears every sibling and per-page precision buys
  nothing): `cache-invalidate *` (Clear All), theme/layout activation,
  the nav-change full invalidation, and backup restore (backups exclude
  `lazysite/cache`, so a restored tree would otherwise keep serving
  pre-restore alias renders). The processor itself needs no hook: a
  source newer than a slot's render re-renders on that host's next
  request, the same mtime rule as the sibling.

Registries (sitemap, search index, feeds) are shared site-global artefacts
written into the docroot, so the host-pollution risk applies to them
directly: registry regeneration is skipped on alias-host requests and left
to the next primary-host render. Corollary: a per-host `search_default`
override affects render-time TT variables only - the shared search index
and page scans (`peek_search_default` reads the raw conf) stay governed by
the base value, consistent with those artefacts being site-global.

The manager Cache page lists primary-host renders; a note on the page
records that alias-host copies are cleared together with a page's
Invalidate and by Clear All. Listing host copies individually is a
possible later refinement, not a correctness need.

## Template exposure

`alias_host`
: TT variable carrying the active alias host (`brand2.example`), empty
  string on the primary and on undeclared hosts. Lets a layout branch per
  host or mark canonical links
  (`[% IF alias_host %]<link rel="canonical" ...>[% END %]`). Canonical
  links are NOT auto-injected - that stays a later candidate, once the
  right default (canonical to primary vs per-host canonical) has a real
  use case behind it.

Request-derived variables (`site_url` via `${SERVER_NAME}`, `request_uri`)
render with the request's own values naturally, as today.

## Phases

Phase 1 (BUILT)
: `alias_hosts` + whitelisted `alias.<host>.<key>` overlay in
  `resolve_site_vars`; sanitised host matching; alias requests NOCACHE
  (interim); registry-regen skip; `alias_host` TT var; conf docs;
  integration tests.

Phase 2 (BUILT - same release)
: host-keyed page cache (per-host slots under `lazysite/cache/hosts/`,
  replacing the interim NOCACHE) with exhaustive invalidation across every
  cache-clearing surface; Cache-page note. Still open from the phase-2
  list: optional canonical link auto-injection; a manager surface to
  *view* configured aliases (read-only first).

Phase 3+ (open, needs design - from the original capture)
: per-alias access scoping (an alias names an owning group; intersects
  SM095 group capabilities and must reach control API / MCP / WebDAV,
  which also arrive on a Host); restricting an alias to a content subtree
  (a blog alias serving only `/blog`); per-alias published-site auth
  domain interaction.
