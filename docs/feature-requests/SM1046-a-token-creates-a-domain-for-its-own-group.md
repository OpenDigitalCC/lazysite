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
status-note: "SHIPPED (PENDING): ruled 2026-10-12 \"Allow, own group only\". An unscoped manage_domains token may domain-add naming its own groups in allowed_groups; a folder outside every domain, an existing one adopted unless an access rule touches it (D-2); audited with the group. t/integration/200, t/unit/auth/51."
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
- the content root must lie outside every domain (`Domains::creation_root_refusal`):
  not equal to, inside or containing any configured domain's root (the
  primary's too, when it has one). An existing folder is adopted (D-2) unless
  it is protected: held in the private store, or touched by any access rule -
  its own, one below it or one above it. An access store that cannot be read
  refuses an existing folder;
- `domain_add` then validates the root as it always did (inside the docroot,
  not reserved) and writes `allowed_groups` with the other keys.

Neither SM975's no-scope refusal nor SM976's root-in-scope check is asked on
this path, because both refuse every root to a caller with no scope. After the
write the account's scope is the new root, so it reaches the new domain and no
other - and, being scoped now, it no longer reaches the primary site's domains
(SM976 R3).

A TOKEN WITH A SCOPE keeps SM976's check (the root inside its scope). Naming a
group adds the own-group and root checks to it, and a root inside its
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

# Decisions, ruled 2026-10-12

Four decisions were taken while building and put to the release manager, who
ruled on each the same day, in these words:

- D-1, own group means direct membership, not the nesting closure: "Direct
  members only". As built (n511).
- D-2, the root must not already exist: "Allow adoption". An existing folder
  may be adopted as the new domain's content root, but only if it is outside
  every domain; the refusal stays for a root that equals, sits inside or
  contains any domain's root. Built on n512, with protected folders kept
  refused (below).
- D-3, naming a group does not also require `manage_users`: "Not required". As
  built (n511).
- D-4, an empty content root is accepted on this path: "Accept". As built
  (n511).

# D-2: what an adopted folder exposes

Measured before building (tmp/n512-adopt-probe.pl, the existence refusal
disabled): a cookie user `pat` in the adopting group and also in a group on
another domain, so scoped to that domain beforehand.

- A PUBLIC folder: before, `pat` was refused read and save by scope; after, it
  read the page and overwrote it. Its existing content becomes the group's to
  read and write, which is what the ruling allows. Anonymous serving was
  unchanged: the page was public at the primary's path and is public at the new
  host.
- A PROTECTED folder (gated with acl-set, so its content moved to the private
  store, read and write `boss`): after adoption `pat` was still refused read
  and save, by the rule instead of the scope, and anonymous requests on the new
  host did not serve it. But `protected-sections`, empty for `pat` before, now
  showed the section with its owner and its read and write lists. A rule whose
  write list is empty (the case acl-set warns about, "READ IS RESTRICTED AND
  WRITE IS NOT") let `pat` overwrite the gated page, still unable to read it
  (tmp/n512-probe-empty-write.sh). And the adopting
  token, which is not on the read list either, cannot read the content it would
  be handing to its group.

That is wider than the ruling's "the group reaches the new domain": it hands
other members the rule and, with an empty write list, write access to content
held back by its owner. So a protected folder stays refused: one held in the
private store, or one that any access rule touches - its own, one below it
(`sites/mixed` with a gated `sites/mixed/inner` is refused), or one above it,
a site-wide rule included (`Acl::rule_keys_touching`). The operator can still
point a domain at protected content from the Domains page.

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
  `other.example.org`; a reserved root refused as before;
- D-2: `sites/held` (gated whole, in the private store) and `sites/mixed` (a
  gated folder inside) refused, naming the rule; `sites/existing` (public,
  outside every domain) adopted by a second partner, its content untouched,
  and that partner then reaches that domain alone;
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

D-2 (n512): t/integration/200 fails with n511's root rule (2 subtests).
Sabotaged three more ways (tmp/n512-sabotage.sh, restored by cp, cmp clean):
protection not asked; a rule below the folder not counted; the overlap check
removed. Each fails.

# Related

[[SM975]], [[SM976]], [[SM647]], [[SM1016]], [[SM1045]].
