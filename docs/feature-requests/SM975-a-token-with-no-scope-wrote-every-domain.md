---
id: SM975
title: "SM975: A token with no scope wrote every domain"
subtitle: "A manage_domains token that nobody had scoped could set, add, remove, remap and overwrite any domain on the instance, and remap a host the instance does not serve."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-09
raised-by: the developer agent, found during SM944 S22 (moving the remap actions)
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-09, no scope = no domain. An unscoped token is refused on domain-set, domain-add, domain-alias-add, domain-remove, remap-save, site-backup-apply and MCP domain_set; remap-list shows it no rules. Scoped tokens and the cookie operator unchanged. t/integration/111."
---

# What was wrong

A token's scope is the content roots of the domains whose `allowed_groups`
name its group. A token with `manage_domains` whose group no domain names has
an empty scope. SM648 says such a token "reaches no domain rather than every
one", and the site-package verbs (SM578) and the data tables (SM648) already
work that way. The domain writes did not:

- `domain-set` and `remap-save` (`_remap_host_in_scope`, now in
  `Lazysite::Manager::Remap`) skipped their scope check when the scope was
  empty. `remap-save` accepted a host the instance does not serve.
- `site-backup-apply` skipped its target check when the scope was empty, so it
  applied a package over any domain or the default site.
- `domain-add`, `domain-alias-add` and `domain-remove` on the control API, and
  `domain_set` on MCP, did not consult the scope at all.

The probe (tmp/sm944-s22-token-scope-probe.pl, then
tmp/q15a-domain-reach-probe.pl) returned ok for every one of these with an
unscoped token.

# The ruling

Release manager, 2026-10-09: "No scope = no domain". A token reaches only the
domains its scope names, and an empty scope reaches none. The cookie session
is the operator and is unaffected. The ruling covers domain reach only.
Content reach stays as documented: an unbound WebDAV, MCP or control-API
account still reaches the whole primary site's content (`_confine_scope`, the
DAV `authorise`, MCP's path confinement, `whoami` showing `allow: /`).

# The fix

`Lazysite::Manager::Common::no_scope_refusal` is the one refusal, and it says
how to give a token a scope. The manager API refuses an unscoped token before
`domain-add`, `domain-alias-add`, `domain-set` and `domain-remove`, and at the
top of `action_site_backup_apply`. `_remap_host_in_scope` answers no for a
token with no scope, `remap-save` returns the refusal, and `remap-list` lists
none of its rules. MCP `domain_set` refuses a grant with no scope, as
`site_backup` and `site_apply` already did.

**Behaviour change:** an existing unscoped token loses its domain writes until
it is given a scope. The operator gives it one by naming the token account's
group in the domain's `allowed_groups` (Domains page, or `domain-set` with
key `allowed_groups` from the operator's own session).

# Evidence

t/integration/111 makes the following assertions:
- An unscoped token is refused on each write above, for a served domain and for
  an unserved host, and nothing is written.
- A token scoped to one domain still writes that domain and is refused outside
  it.
- The operator still writes every domain.
- MCP `domain_set` refuses an unscoped grant and accepts a scoped one.

With the three files restored to their n308 reading (tmp/q15a-sabotage.sh),
the test fails. Restored by cp and checked with cmp, it passes.

# Found, not changed

These were probed and are reported for a ruling. They concern scoped callers,
which this ruling leaves as they were:

- A SCOPED token's `domain-add` (any content_root), `domain-alias-add` (an
  alias of any domain) and `domain-remove` (any domain) are not checked
  against its scope. All three returned ok outside the token's scope.
- MCP `domain_set` checks neither the scope of a scoped grant nor SM647's
  `manage_users` requirement for `allowed_groups` and `locked_users`. A grant
  scoped to one domain set `allowed_groups` on another.
- `_root_outside_grant` exempts every cookie session, including a scoped
  non-operator manager, although SM154 confines those managers on content
  paths. A cookie manager scoped to one domain built a package of another domain
  and deleted another domain's package (tmp/q15a-cookie-scoped-probe.out).
  `site-backup-inspect` refused, because its second check reads
  `@REQUEST_SCOPES`.

# Related

[[SM578]], [[SM647]], [[SM648]], [[SM944]].
