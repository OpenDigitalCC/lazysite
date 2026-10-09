---
id: SM976
title: "SM976: A confined caller reached other domains on every surface"
subtitle: "A token, MCP grant, WebDAV account or cookie manager confined to one domain added, aliased, removed, configured, packaged and re-navigated other domains; one rule now answers for every host-addressed action."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-09
raised-by: the developer agent, from the gaps SM975 found and did not change
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-09 \"One rule, fix all\". Every host- or root-addressed action on the control API, MCP and WebDAV asks Manager::Common::caller_may_reach_domain; a confined caller reaches only its own domains, the operator all. t/integration/112, t/unit/manager/207, t/unit/data/66, t/lint/218."
---

# What was wrong

SM975 made a token with no scope reach no domain, and recorded what it found
for scoped callers without changing it. Probed on main 4cd9f808
(tmp/q15b-reach-probe.pl, 228 cells; before and after in
tmp/q15b-reach-probe.before.out and .after.out):

- A token scoped to one domain ran `domain-add` at any content root,
  `domain-alias-add` of any domain and `domain-remove` of any domain.
  `domain-set` let it repoint its own domain's `content_root` at another
  domain's content, which moved its scope there, and set keys on a domain with
  no content root of its own (one serving the primary's content).
- MCP `domain_set` asked neither the scope of a scoped grant nor SM647's
  `manage_users` requirement for `allowed_groups` and `locked_users`. A grant
  scoped to one domain wrote another domain's access groups. `activate_theme`
  and `activate_layout` with a `host` are the same write and asked nothing,
  not even SM975's scope check.
- `_root_outside_grant` exempted every cookie session, so a cookie manager
  scoped to one domain built, downloaded and deleted another domain's site
  package. `site-backup-apply` with no host (the primary) and a `content_root`
  inside the caller's scope rewrote the primary's presentation.
- The navigation: `nav-read`/`nav-save` and `read_nav`/`set_nav` never asked
  about `host`. A grant scoped to one domain read and replaced every other
  domain's navigation, and the primary's. WebDAV (tested as asked): a nav file
  returned allowed before the scope check, so a scoped WebDAV account GOT and
  PUT another domain's nav file and the primary's `lazysite/nav.conf`.
- Listings and reads: `domains-list`/`list_domains` showed a confined caller
  every domain's content root, access groups and address; `domain-preview`,
  `preview_domain`, `domain-check` and `aliases-list` answered for any host.
- The data surface: `data-table-save` let a confined caller bind a table to a
  domain it does not reach - create a table in another domain, or move its own
  there (tmp/q15b-data-probe.pl).

# The ruling

Release manager, 2026-10-09: "One rule, fix all". A domain-confined caller -
token, MCP grant, or scoped (non-operator) cookie manager - reaches only its own
domains on every surface; the unconfined operator is unaffected.

# The rule, built

`Lazysite::Manager::Common::caller_may_reach_domain( host => H | root => R )`,
with `domain_reach_refusal` (the refusal, naming the caller's scope and the
domains it does reach) and `reachable_domains`.

Who is confined
: A token, always. A cookie manager with a scope. Over MCP and WebDAV every
  caller is a grant, passed as `scopes => [...]`. The cookie operator, and a
  cookie manager whose groups bind no domain, are unconfined - an empty scope on
  the cookie channel is no confinement, as for its content paths, and as every
  domain action already treated it.

The answer for a confined caller
: A host the instance does not serve: no. A domain with its own content root:
  yes when the root lies inside one of its scopes, no otherwise, and no for an
  empty scope (SM975). The primary, and a domain with no root of its own (it
  serves the primary's content): the content-path rule SM975 kept - an unbound
  grant reaches the primary site, a scoped one does not. The domain writes and
  site packages keep SM975/SM578's outright refusal of a token naming no scope
  ahead of this.

A navigation file
: Reading needs one domain the file is the navigation of; writing needs every
  one, since a file shared by inheritance changes each site that inherits it.

A new content root
: `domain-add` and `domain-set content_root`: the root must lie inside the
  caller's scope.

# Every host- or root-addressed action, and how it asks

Control API (`lazysite-manager-api.pl`): `domain-add` (content_root),
`domain-alias-add` (alias_of), `domain-set` (host; new content_root),
`domain-remove`, `domain-preview`, `domain-check` and `cache-invalidate` (host)
through `_refuse_unreachable_domain`; `aliases-list` (host, else the domain
owning `path`, else the primary); `domains-list` filters its rows;
`site-backup-create`/`-inspect`/`-download`/`-delete` and `backup-list` through
`_root_outside_grant`/`_package_scope_refusal`, which now hold a scoped cookie
manager too; `site-backup-apply` asks of the target domain and its root;
`site-export-primary` asks of the primary; `remap-save`/`remap-list` through
`Manager::Remap::_remap_host_in_scope`; `nav-read`/`nav-save` in
`Manager::Nav`. MCP (`lazysite-mcp.pl`): `domain_set`, `preview_domain`,
`site_backup`, `site_apply`, `activate_theme`/`activate_layout` with host,
`read_nav`, `set_nav`, `list_domains`. WebDAV (`lazysite-dav.pl`): both
navigation branches of `authorise` through `_nav_reach_deny`. Data:
`data-table-save` checks a descriptor's `domain:` by the data surface's own rule
(below).

`t/lint/218` holds this: every control-API action that takes or reads a host,
content root or alias, every listing and package verb, every MCP tool with a
`host` or `content_root` argument and both WebDAV nav branches ask the rule,
directly or through a sub that does; an exception is a closed list with a
reason.

# Behaviour change

A scoped token, MCP grant, WebDAV account or cookie manager is refused on
another domain, on the primary, on a host the instance does not serve and on a
domain serving the primary's content; its listings show its own domains only.
An unbound token, MCP grant or WebDAV account reaches no domain's navigation;
it still reads the primary's, and writes it unless a domain with a content root
of its own inherits that file. Single-site instances are unaffected. The operator and an unbound cookie
manager are unchanged. A scoped cookie manager's Nav page opens on its first
domain.

# Evidence

- t/integration/112 is the probe as assertions: every cell, the operator and
  the unbound cookie manager served, the confined callers refused outside their
  domains and served inside them, and a single-site instance where an unbound
  grant keeps the primary's nav on all three surfaces.
- t/unit/manager/207 is the predicate's truth table; t/unit/data/66 the table
  binding.
- Before and after on main's probe: 165 cells unchanged (no refusal became a
  success), 63 ok-to-refused, all of them the gaps above
  (tmp/q15b-same-answers.out).
- Sabotage: the predicate answering yes for everyone fails 112 and 207; the data
  check removed fails 66; one action's call removed fails lint 218.

# Found, not changed

- The data surface keeps its own reach rule (SM593/SM648): a grant reaches a
  domain's tables when its scope and the domain's root overlap in either
  direction, and a cookie manager bound to no domain is confined to none. This
  rule is containment and leaves that manager unconfined. Aligning them is a
  narrowing on one side and a widening on the other, so it is for a ruling.
- Instance-wide verbs (`config-set`, `theme-activate`, `layout-activate`, MCP
  `activate_theme`/`activate_layout` without a host) change every domain and
  are gated by capability alone. Measured: a token scoped to one domain, with
  `manage_config`, rewrote the instance's `site_name` through `config-set`
  (tmp/q15b-instance-wide-probe.out); the others by reading. Whether a
  domain-confined caller may hold an instance-wide capability is for a ruling.

# Related

[[SM975]], [[SM943]], [[SM578]], [[SM647]], [[SM648]], [[SM802]].
