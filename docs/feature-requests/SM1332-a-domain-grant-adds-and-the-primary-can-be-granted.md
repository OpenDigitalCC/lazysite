---
id: SM1332
title: "SM1332: a domain grant adds, and the primary can be granted"
subtitle: "Naming an account's group on a secondary domain took the primary away from it, because the primary was reached only by having no scope at all, and there was no primary row to grant it back on. Ruling 78: the primary is a grantable row, grants add, an account granted nothing keeps the primary, and only a pin removes the others. Nothing changes at upgrade."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "the 2026-11-05 filing (inbox/2026-11-05-a-domain-scope-takes-the-primary-away.md), triage T-40, ruling 78 (Q10)"
area: security
status-note: "SHIPPED (0.16.5) on n746: DomainAccess grants the primary on its row (PRIMARY_SCOPE, the docroot); caller_may_reach_domain reads it as the primary only; the content checks (WebDAV, MCP, manager list) read it as the whole docroot; the processor's copy agrees. t/unit/lib/210, t/unit/manager/425, t/unit/dav/37, t/unit/processor/175."
---

# What happened

On 0.16.2 an agent account that had worked on the primary site lost it the day
its group was added to one secondary domain. A domain's `allowed_groups` gives
every member a scope, the content root of that domain, and
`Lazysite::Manager::Common::caller_may_reach_domain` (SM975, ruled 2026-10-09
"Keep for primary") let an account reach the primary only when it had **no**
scope at all. So the first grant anywhere took the primary away. The primary had
no row where a group could be added back: its reach was the absence of a scope,
not a grant.

The owner: "Only when a user is pinned to a domain should other access be removed
(and maybe this is a group, not a user)."

# The ruling

Ruling 78 (Q10): the primary is a grantable row in the domain list. Grants are
additive: an account or group reaches every domain it is granted, the primary
included when granted. An account with no grant anywhere keeps the primary.
Only pinning removes the others (`home_domain`, for an account or a group). No
change at upgrade; the domain screen shows the primary row.

# What shipped

- **The primary's row carries `allowed_groups`.** In `lazysite.conf` it is the
  bare `allowed_groups:` line, as the primary's content root is the bare
  `content_root:` line. `Lazysite::Auth::DomainAccess::read_domains` reads it
  (and the bare `locked_users:`).
- **A grant on the primary adds the primary's scope**, `PRIMARY_SCOPE`: `/`, the
  docroot, which is the primary's content root. An account in `agent-ai`, with
  `agent-ai` named on harmony.test and on the primary, now has
  `dav_scopes: ["/", "sites/harmony"]` (whoami shows the same list).
- **Granted nothing, it keeps the primary**, as an unbound account always did:
  its scope list is empty. A primary row naming some groups does not take the
  primary away from an account granted nothing anywhere.
- **The domain rule reads the primary's scope as the primary only.** By path the
  docroot contains every domain's content root, so read that way the grant would
  reach every domain; `caller_may_reach_domain` sets it apart. It reaches the
  primary and a domain with no content root of its own (which serves the
  primary's content), and the other domains are reached by their own scopes.
  Every surface asks this one rule (t/lint/218): the manager's Domains list,
  the control API, MCP `list_domains`, `domain_set`, the site packages, visitor
  stats, remaps, nav, forms, briefs and data tables. The start-page check
  (`Lazysite::Manager::StartPage`), which compared roots itself, asks it now
  too.
- **The content checks read it as the whole docroot**, as they read an unbound
  account's empty list: WebDAV `authorise` (which skipped a scope with no folder
  in it), MCP's path confinement, the control API's `_confine_scope`,
  `caller_may_reach_path`. A confined caller naming no folder in `list` is shown
  the docroot, as MCP `list_files` already was (its walk roots treat a docroot
  scope as no confinement).
- **The served-artifact rule agrees.** "Served by a site you do not reach" is
  decided by the same rule, so a theme the primary serves is writable by an
  account granted the primary and every other site serving it. When the site not
  reached is the primary, the refusal says the primary is granted on its own row.
- **The refusal names the primary row.** A caller scoped to other domains asking
  for the primary is told: "The primary site is granted on its own row, as any
  domain is: an operator names the account's group in the (default) domain's
  allowed_groups (Domains page)." A scope list is named as "the primary site,
  sites/alpha/", never as a bare `/`.
- **Instance-wide writes follow the primary.** `caller_is_confined` (SM976 R1)
  held an account confined because its scope was not empty; the reasoning was
  that such an account never reached the primary, whose settings the instance's
  are. An account granted the primary reaches it, and is not confined there, as
  an unbound one is not.
- **The sub-user ceiling** (`intersect_scopes`): the primary's scope meets only
  itself. By path it would contain the creator's domains, and a sub-user granted
  only the primary would come out holding them.
- **The processor's copy** (`lazysite-processor/acl.pm`, the file browser's
  rooting) reads the row the same way, and the Files page offers the primary in
  its domain switcher as "the primary site".

# No change at upgrade

No primary row named a group before, so no account is granted the primary, and
every scope is what it was: an account scoped to a secondary keeps exactly that
domain and does not gain the primary. The operator grants the primary on its row.
t/unit/lib/210 holds it on a fixture of today's data, with the answers the
resolver gave before this change written out.

# Reach

Reach widens only through an explicit grant on the primary's row, and only to
what an unbound account already had (the primary's content and settings), added
to the domains the account was granted. Nothing widens at upgrade.

# Tests

- t/unit/lib/210: the upgrade fixture (unbound, scoped, two grants, a lock); the
  primary row read; a primary grant added to a secondary; the primary alone;
  only a pin removes the others; the ceiling; `is_primary_scope`.
- t/unit/manager/425: the reach table for a primary grant (beta, not granted,
  stays out of reach), the listing, the content paths, instance-wide writes, a
  theme the primary serves, the refusal text.
- t/unit/dav/37: over WebDAV, an account scoped to one domain reaches the
  primary's content only once the primary row names its group.
- t/unit/processor/175: the processor's copy agrees with the module.
