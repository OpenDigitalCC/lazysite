---
id: SM1046
title: "SM1046: a token creates a domain for its own group"
subtitle: "A manage_domains token with no scope could not create the first domain it would manage; it may now, when it names one of its own groups as the domain's allowed_groups."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox report 2026-10-12, sites.lazysite.io (engine 0.15.4)
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-12 \"Allow, own group only\". An unscoped manage_domains token may domain-add naming its own groups in allowed_groups; a new folder outside every domain; audited with the group. t/integration/200, t/unit/auth/51."
---

# What was wrong

On sites.lazysite.io the API account `claude-code`, holding `manage_domains`,
sent `domain-add` for `tprf-news.sites.lazysite.io` and was refused: "A token
reaches only the domains its scope names, and this grant names no dav_scope,
so it reaches no domain." (SM975). The remedy the message gives is a domain
that names the account's group, which is the domain it was asked to create. So
an operator had to create every domain by hand before a partner holding
`manage_domains` could do anything with it.

# The ruling

Release manager, 2026-10-12, "Allow, own group only":

- a token holding `manage_domains` may create a domain without a prior scope
  when the request names one of the caller's own groups as the new domain's
  `allowed_groups`;
- refused if the group is not one the account holds, so a partner can hand a
  new domain only to itself or to a group it is already in;
- refused, with a message saying to name one, if none is named;
- the content root validated as now (inside the docroot, not reserved, not
  another domain's root), and SM976's content-root-in-scope check reconciled
  so that it does not refuse the creation;
- audited with the caller, the host and the group;
- no reach to existing domains changes; the operator can still remove or
  reassign the domain. MCP has no `domain-add` tool, and the CLI is the
  operator's and unchanged.

# What it does

`domain-add` on the control API reads `allowed_groups` (a comma string or a
JSON array; `@name` and `name` are the same group).

THE CREATION RULE, for a token with no scope that names groups:

- every group must list the account by name (`Settings::direct_groups`). A
  parent group the account inherits through nesting is not its own: that group
  reaches its other members and every group nested in it, so the narrower
  reading of "groups its own account belongs to" was taken;
- the content root must be new content (`Domains::creation_root_refusal`): not
  equal to, inside or containing any configured domain's root (the primary's
  too, when it has one), and not a folder that already exists, public or in the
  private store;
- `domain_add` then validates the root as it always did (inside the docroot,
  not reserved) and writes `allowed_groups` with the other keys.

Neither SM975's no-scope refusal nor SM976's root-in-scope check is asked on
this path, because both refuse every root to a caller with no scope. After the
write the account's scope is the new root, so it reaches the new domain and no
other - and, being scoped now, it no longer reaches the primary site's domains
(SM976 R3).

A TOKEN WITH A SCOPE keeps SM976's check (the root inside its scope). Naming a
group adds the own-group and new-content checks to it, and a root inside its
scope is inside one of its domains, so in practice it is refused: a scoped
token creates a domain as before, without `allowed_groups`.

A TOKEN NAMING NO GROUP is refused with SM975's refusal and a sentence saying
to name one of its own groups, listing them.

A SIGNED-IN SESSION naming `allowed_groups` on `domain-add` is refused and
pointed at `domain-set`. That key was never read from this action; accepting
it from a cookie would be a second door past SM647's `manage_users` rule and
SM1016's existence check, which `domain-set` asks.

AUDIT. The success row is the action `domain-add`, the user the caller, the
target the host, and the detail `allowed_groups=<groups> (own group, SM1046)`.
The engine log line for the domain carries `allowed_groups` too. Each refusal
is audited with its reason.

# Decisions taken while building, for review

- D-1: own group means direct membership, not the nesting closure (above).
- D-2: the root must not already exist. The ruling says the root is validated
  "as now", which allows adopting an existing folder. Adoption would give the
  folder's existing content to every member of the group, including members
  scoped elsewhere, who did not reach it before. The narrower rule was built;
  the operator still adopts existing content from the Domains page. If adoption
  is wanted on this path, it is a one-line change in `creation_root_refusal`.
- D-3: `allowed_groups` naming does not also require `manage_users`. SM647
  requires it for `domain-set`'s access keys because those confer reach on any
  group; this path confers reach only on the caller's own group, which the
  ruling allows to a `manage_domains` holder.
- D-4: an empty content root (a host serving the primary site) is accepted on
  this path. It adds no scope to anyone.

# Not changed

Reach to existing domains, `domain-set`, `domain-remove`, `domain-alias-add`,
remap and site packages: SM975 and SM976 as they were. An operator who later
adds a domain inside a partner's root puts it in the partner's scope, as any
nested root does today.

# Tests

t/integration/200 (control API, a token as the report sent it):

- naming no group: refused, forbidden, the SM975 sentence plus "name one of
  your own groups", listing `partners`; nothing written;
- naming `strangers`, `[@strangers]`, `partners, strangers`: refused, naming
  `@strangers` and the groups it may name; nothing written;
- roots `sites/other`, `sites/other/news`, `sites`: refused, naming
  `other.example.org`; an existing folder refused; a reserved root refused as
  before;
- the reported case: `@partners` creates `tprf-news.example.org`, conf names
  the group, the root exists, one audit row with caller, host and group;
- afterwards: `domains-list` shows the new domain alone; it sets a key there,
  is refused on `other.example.org` (domain-set and domain-remove), and a
  second own-group domain is refused by SM976 because it is scoped now;
- the operator reassigns the domain (the partner no longer reaches it) and
  removes it;
- a signed-in session naming `allowed_groups` on `domain-add`: refused.

t/unit/auth/51: `direct_groups` is the groups naming the account, not its
nesting parents.

t/integration/111 (SM975) and 112 (SM976) pass unchanged.

Fails on n510 (7 of 9 subtests). Sabotaged four ways (tmp/n511-sabotage.sh,
restored by cp, cmp clean): any group accepted as own; no new-root check; the
group left out of the audit row; the creation path skipping SM976 for a scoped
token. Each fails.

# Related

[[SM975]], [[SM976]], [[SM647]], [[SM1016]], [[SM1045]].
