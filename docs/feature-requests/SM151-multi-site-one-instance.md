---
title: "SM151 - First-class multi-site: many domains, one instance, one login"
subtitle: "Per-domain content roots, SEO and search on top of the SM110 alias plane"
brand: plain
status: partial
status-note: "spec approved 2026-07-13; P1 (content_root routing + confinement core, S1/S2/S6) built on branch claude/multisite with the adversarial gate t/integration/17-multisite-content-root.t. Remaining: P2 per-host site_url/canonical, P3 per-domain registries, P4 boxed search, P5 Domains manager view + Host in access log. Subsumes SM110 phase 3; distinct from SM075."
---

::: widebox
One lazysite instance serves many domains. Each domain is rooted at its own
content subtree and is, to the outside world, a complete first-class site -
its own home page, navigation, theme, canonical URL, sitemap, robots, feeds
and search. Behind the scenes there is one docroot, one auth store, one
manager and one AI/MCP endpoint, so the operator logs in once and drives all
of them with a single credential. The design target is an agency running its
own portfolio of client sites: **one user, one AI, N public sites.**
:::

# SM151 - First-class multi-site under one instance

## 1. Goal and motivation

An agency runs ~10 client sites. Today that is ~10 lazysite instances: ten
manager logins, ten `claude.ai` MCP connections, ten of everything to patch
and watch. The agency is a **single trust domain** - one team edits all the
sites, no client wants their own login yet, and if a client later takes their
site in-house it is migrated out to its own space (feasible in Hestia).

The requirement is therefore *not* multi-tenant isolation. It is the opposite:
collapse ten sites onto **one management plane** (one login, one AI token, one
thing to run) while each domain remains, to an external viewer and to search
engines, an independent first-class site.

## 2. Relationship to prior work

This is a deliberate composition of two earlier captures. It is neither of
them on its own.

```datatable
columns: Feature | What it is | Relationship to SM151
widths: 3cm | X | 5.5cm
bold: 1
tone: medium
---
SM110 (built) | One docroot, many hosts, shared content + auth, per-host chrome (site_name/theme/layout/nav) via `alias_hosts` + `alias.<host>.<key>`. | **Foundation.** SM151 extends its config model and per-host cache, and delivers its parked "phase 3" (subtree rooting + per-alias registries).
SM075 (parked) | Many docroots via wildcard `VirtualDocumentRoot`; each host has its own `lazysite/` state - isolated content **and auth**. | **Rejected for this use case.** Per-host auth stores would put the agency back at N logins / N tokens. SM075 stays the right answer for mutually-distrustful throwaway tenants.
External OAuth (separate FR) | One identity across many *separate* instances. | **Out of scope here** and tracked separately. It gives human SSO but not one AI endpoint; the agency's "one AI" goal is met by the single instance, not by federation.
```

## 3. Model

One docroot. One `lazysite/` management tree (auth, secret, ACLs, themes,
layouts, config, logs, backups) at the docroot root - shared by every domain.
Content is partitioned into **per-domain subtrees**. A domain's `Host` selects
its subtree; requests to that host are served, rendered, indexed and linked as
though that subtree were the whole site.

### 3.1 On-disk layout

```
<docroot>/
  lazysite/                 # shared management plane (ONE of each)
    lazysite.conf           #   all domains declared here
    auth/                   #   one users/groups/secret/acls store
    themes/  layouts/       #   shared, reused across domains
    cache/hosts/<host>/     #   per-host render cache (SM110 phase 2)
    logs/  backups/
  sites/
    clientA/                # domain A content root
      index.md  ...  assets/
    clientB/                # domain B content root
      index.md  ...
```

The `sites/<client>/` split is a convention, not a requirement; the content
root of each domain is whatever the operator names in the conf (§4). A bare
docroot with no configured roots behaves exactly as today (SM110 unchanged),
so this is a pure superset - zero behaviour change when unused.

## 4. Configuration reference

Two additions to the SM110 conf model. Aliases remain operator conf-file
territory (not settable through the manager/control API, same as SM110).

`content_root`
: New whitelisted per-host override. A docroot-relative directory that becomes
  the domain's `/`. Example: `alias.clientA.example.content_root: sites/clientA`.
  A top-level `content_root:` may also set the primary host's root. Unset =
  serve from docroot root (today's behaviour).

`site_url`
: Promoted into the alias override whitelist so each domain carries its own
  absolute base URL for canonical links, sitemap and feeds. Example:
  `alias.clientA.example.site_url: https://clientA.example`. Unset = the base
  `site_url` (which itself already defaults to `${REQUEST_SCHEME}://${SERVER_NAME}`).

The override whitelist (`%ALIAS_OVERRIDE_KEYS`, `lazysite-processor.pl:275`)
grows from `site_name theme layout nav_file search_default` to add
`content_root` and `site_url`. Security-relevant keys stay **non-overridable**
exactly as in SM110 (`manager`, `auth_*`, `webdav_*`, `update_*`, `log_*`,
`plugins`) - a request-supplied `Host` must never be able to move the auth,
management or update surface.

Example `lazysite.conf` fragment:

```
site_name: Agency Home
alias_hosts: clientA.example, clientB.example

alias.clientA.example.site_name:    Client A
alias.clientA.example.content_root: sites/clientA
alias.clientA.example.site_url:     https://clientA.example
alias.clientA.example.theme:        harbour
alias.clientA.example.nav_file:     sites/clientA/nav.conf

alias.clientB.example.site_name:    Client B
alias.clientB.example.content_root: sites/clientB
alias.clientB.example.site_url:     https://clientB.example
alias.clientB.example.theme:        ledger
```

## 5. Request resolution and routing

Anchors are current `lazysite-processor.pl` line numbers.

1. Host is sanitised and matched against `alias_hosts` in `resolve_site_vars()`
   (2697-2757); on match the overlay yields `content_root` and `site_url` for
   this request. Undeclared / malformed hosts get the base conf (unchanged).
2. `sanitise_uri()` (1239-1268) produces the safe base name, including the
   hardcoded `/index` home handling - unchanged.
3. The on-disk path computation (960-962) gains a root prefix:

   ```perl
   my $base = sanitise_uri($uri);
   my $root = confine_content_root($DOCROOT, $sv{content_root}); # §6
   my $md_path   = "$root/$base.md";
   my $url_path  = "$root/$base.url";
   my $html_path = "$root/$base.html";
   ```

4. Per-host render cache already keys on the host (977-981); it continues to,
   so two domains that share a base name never collide.

`/index` stays the home convention: `https://clientA.example/` serves
`<docroot>/<content_root>/index.md`.

## 6. Security invariants (build to these, test each)

Even though all domains share one trust domain, the **public request path is a
hard boundary**: a visitor to one domain must never reach another domain's
files or the management tree. These are non-negotiable and each gets a test.

```datatable
columns: # | Invariant | Enforcement
widths: 1cm | 5.5cm | X
bold: 2
tone: medium
---
S1 | The served path is confined under the domain's content root. | `confine_content_root()` resolves the joined path with an abspath/realpath check and asserts it is a prefix of the content-root abspath; reject `..`, absolute escapes, and symlinks leaving the subtree. `sanitise_uri` already strips traversal; the post-join re-check is defence in depth.
S2 | A content root can never be, contain, or alias into `lazysite/`. | Validate at conf load: content root must resolve under `$DOCROOT` and must not equal or sit inside `$LAZYSITE_DIR`. Existing `/lazysite/` request blocklist stays. Secrets, auth and ACLs are never web-reachable through any domain root.
S3 | Per-domain identity comes only from declared config. | `site_url` / canonical derive from the alias overlay, never from `HTTP_HOST` (already excluded from `%ENV_ALLOWLIST`, 259-266). Only hosts listed in `alias_hosts` get a non-base root.
S4 | Security keys remain non-overridable per host. | Unchanged SM110 whitelist gate (275-276, 2727-2738); `content_root`/`site_url` are presentation/routing only, not auth or management.
S5 | One broken domain cannot serve another's content from cache. | Cache stays host-keyed (977-981); invalidation clears per-host copies (`unlink_host_copies`/`clear_host_cache`, Util.pm:181-213). Content-root change for a host invalidates that host's cache slot.
S6 | A malformed alias entry degrades only that host. | Alias parse is best-effort per host: a bad `content_root` logs WARN and that host falls back to base (or a 503 for that host), never aborts the instance or affects siblings.
```

## 7. SEO - each domain a first-class site

Registries are generated by `update_registries()` (3087-3180) from templates
in `lazysite/templates/registries/` and are currently **site-global and
skipped on alias requests** (3094). SM151 makes them per-domain.

- **Canonical.** Layouts emit `<link rel="canonical" href="[% site_url %][% page.url %]">`
  using the per-host `site_url`. Optional auto-injection (the open SM110
  phase-2 item) can live here.
- **sitemap.xml / robots.txt.** Generated per content root, written into that
  root (`<content_root>/sitemap.xml`), scanning only that subtree
  (`scan_pages()`, 3183-3236, narrowed to `$root`) and using the domain's
  `site_url` for absolute links. `robots.txt` references the domain's own
  sitemap.
- **feeds (RSS/Atom).** Same: generated per content root, absolute URLs from
  the domain's `site_url`.
- **Generation trigger.** Per-host registries regenerate on write within that
  subtree and on a TTL, keyed by host so one domain's refresh never stamps on
  another's. The current "skip on alias" short-circuit (3094) is replaced by
  "regenerate for this host's root".

## 8. Search - boxed per domain

`scan_pages()` walks the whole docroot today and the search endpoint
(`starter/search-index.md`, `scan:/**/*.md`) returns a single global index.
SM151 scopes the scan to the requesting domain's content root so a search on
`clientA.example` returns only Client A pages. Implementation: the scan/`scan:`
resolver (`resolve_scan()`, 2860-2890) roots its glob at the request's
`content_root`; the per-host cache keeps each domain's index response separate.

## 9. Navigation, theme, layout

Already per-host via SM110 (`nav_file`, `theme`, `layout` overrides). With
subtree roots, point `nav_file` at the domain's own `nav.conf`
(`sites/clientA/nav.conf`). Themes and layouts stay shared under `lazysite/`
and are reused across domains - a feature, not a limitation, for an agency.

## 10. Manager and AI surface

One auth store → one manager login and one MCP endpoint see everything, by
construction. The manager file browser lists the `sites/*` subtrees; the agency
user edits any domain. The single AI/MCP credential addresses paths under each
subtree (the MCP tools are already path-aware). This is exactly the "one user,
one AI, N sites" outcome, with no federation and no per-tenant auth.

A read-only **"Domains" manager view** (list configured domains, their root,
theme, nav and canonical) is in scope as the SM110 phase-2 leftover, upgraded
to show roots. Editing domains through the UI stays out of scope (conf-file
only) for this cut - see §13.

## 11. Reliability and availability

The single instance is a shared failure domain; the requirement is that it is
engineered not to fall over, and that a fault in one domain cannot take down
the rest.

- **Serving survives the CGI.** Pages are pre-rendered to `.html` in per-host
  cache; the web server's `FallbackResource`/static path can serve cached HTML
  even if the processor is unhealthy. Public availability does not depend on
  the manager being up.
- **No cold-start stampede.** FastCGI worker pools (0.7.1) keep the interpreter
  warm; per-host cache means steady-state serving is static-file fast.
- **Fault isolation between domains.** Per §6 S6, a bad alias/config for one
  domain degrades only that domain. A corrupt page in one subtree does not
  break another domain's cached serving or registries.
- **Blast radius.** One auth secret and one code copy are shared; this is the
  accepted cost of one management plane, mitigated by (a) the public boundary
  of §6, (b) whole-docroot backups (RPO covers every domain at once), and (c)
  the escape hatch of §12 - any domain can be promoted to its own instance if
  it needs an independent failure domain.
- **Health.** A lightweight health endpoint (instance up, conf parses, cache
  writable) for the operator's monitor; conf-parse failure is reported, not
  fatal to already-serving hosts.

## 12. Migration / client takeover

Because each domain is a self-contained subtree, taking a client in-house is a
move, not a rebuild:

1. `git`/`rsync` the domain's `sites/<client>/` tree to a new docroot's root.
2. Provision a standalone instance (Hestia tooling already exists) and seed its
   own `lazysite/` (auth, theme copy, conf).
3. Repoint DNS/TLS to the new instance; remove the alias from the agency conf.

Structuring content per-subtree from day one is what keeps this exit clean, so
it is a first-class design constraint, not an afterthought.

## 13. Out of scope (explicit)

- **Per-tenant auth isolation / client self-service logins.** Deliberately not
  built: the assumption is one trust domain. When a client wants their own
  login, the answer is takeover (§12) or a future scoping layer, not boxing
  them into a shared instance.
- **`dav_scope` enforcement on manager UI / API / MCP.** Only relevant once
  per-tenant boundaries inside one instance are wanted; tracked separately.
- **External OAuth across instances.** Separate feature request.
- **Manager UI *editing* of domains.** Read-only view only this cut.

## 14. Build plan (ordered, each independently testable)

```datatable
columns: Phase | Deliverable | Gate
widths: 2cm | X | 5cm
bold: 1
tone: medium
---
P1 | `content_root` config key + `confine_content_root()` + path-prefix at 960-962; conf-load validation (S1, S2, S4, S6). | Integration test: host→subtree serving; traversal, `lazysite/` reach, and malformed-alias fallback all denied/isolated.
P2 | `site_url` in the alias whitelist; per-host canonical in layouts. | Test: canonical + absolute URLs carry the domain's own host, never `HTTP_HOST`.
P3 | Per-domain registries: `update_registries()`/`scan_pages()` rooted at `content_root`, replace the 3094 skip; per-host sitemap/robots/feeds. | Test: each domain's sitemap lists only its pages with its base URL.
P4 | Per-domain search scoping in `resolve_scan()`. | Test: search on domain A excludes domain B.
P5 | Read-only Domains manager view; access-log line records `Host` (cheap, enables per-domain stats later). | Test: view lists roots; log carries host.
```

## 15. Testing focus

Beyond the per-phase gates, a dedicated `t/integration/` suite asserts every
§6 invariant with an adversarial cast: a request to domain A carrying `..`,
encoded traversal, a symlink into domain B, a path into `lazysite/auth/`, and a
spoofed `Host` for an undeclared domain - each must be confined or fall back to
base, never cross a boundary. This suite is the release gate for the feature.

## 16. Open decisions (need a call before/at build)

- **Key name:** `content_root` vs `root` vs `docroot_subtree`. (Proposed:
  `content_root`.)
- **Canonical source:** always derive from declared `site_url`, or allow a
  `canonical_host` shorthand? (Proposed: `site_url` only, keep it one concept.)
- **Bare-docroot primary host:** landing page, list of domains, or 404 when
  every domain has its own root? (Proposed: configurable; default to the
  existing docroot-root behaviour.)
- **Registry regeneration cost** at N domains: per-write per-host is cheap;
  confirm the TTL sweep stays per-host and lazy.
