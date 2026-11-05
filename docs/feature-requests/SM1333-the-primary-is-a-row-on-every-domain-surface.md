---
id: SM1333
title: "SM1333: the primary is a row on every domain surface"
subtitle: "SM1332 made the primary grantable; this is where the grant is made. domain-set and the access edits take the host (default) for the primary's access keys, the Domains page shows the primary's row with an Access sheet, and a secondary row no longer shows the primary's access as inherited."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "ruling 78 (Q10, triage T-40): \"the domain screen shows the primary row\""
area: security
status-note: "SHIPPED (PENDING) on n746: Domains::domain_set and domain_access_edit take '(default)' (or '') for allowed_groups and locked_users, writing the bare lines; both listings keep each row's access its own; the Domains page lists the primary with an Access sheet; MCP domain_set and lazysite-domains.pl say so. t/unit/manager/426, t/unit/manager/427."
---

# What was missing

SM1332 gave the primary a row of its own in the resolver: the bare
`allowed_groups:` and `locked_users:` lines. Nothing wrote them. `domain-set`
refused the host `(default)` (it is not a valid host name and not among
`alias_hosts`), the Domains page skipped the primary's row ("the default site
lives in Site settings"), and an operator had nowhere to grant the primary.

Both listings (`domains_list`, read by MCP `list_domains` and by Groups, and the
manager's `domains-list`) also let a secondary row inherit every key it does not
set from the primary's. For the presentation keys that is what is served. For
the access keys it never was: `DomainAccess` reads only a row's own lines. With
the primary able to carry `allowed_groups`, every secondary would have shown the
primary's groups as its own (greyed, "inherited"), and Groups, which reads the
row, would have offered them as that domain's.

# What shipped

- **`domain_set('(default)', key, value)`** (and `''`) sets the primary's
  `allowed_groups` or `locked_users`: the same normalisation, the same refusal
  of a name the site does not have (SM1016), the same writer, lock, content
  history commit and log line as any domain's. Any other key is refused, naming
  the Config page: the primary's name, address and appearance are the site's own.
- **`domain_access_edit('(default)', ...)`**, so `lazysite-domains.pl --host
  '(default)' group-add` (and `group-remove`, `user-add`, `user-remove`) edit one
  name in the primary's row.
- **The control API's `domain-set` and MCP `domain_set`** reach it unchanged:
  both call `domain_set`, after the capability rule (an access key needs
  `manage_users` too, SM647) and the reach rule, which asks whether the caller
  reaches the primary. A caller scoped to other domains is refused the primary's
  row and told it is granted there. The refusal names a scope holding the
  primary's grant as "the primary site", never `/`.
- **Listings keep each row's access its own.** A secondary with no access line
  shows none, not the primary's, and is not marked inherited.
- **The Domains page** lists the primary as `(default)` with a "primary" tag and
  an **Access** button. Its sheet holds the groups allowed and the users locked,
  with Save, and nothing else: no content folder, presentation, tools or delete.
  The hint says how a grant there adds. A secondary's hint says grants add.
- **Docs**: the manager guide's "The primary site's row" step; the MCP
  `domain_set` description; `lazysite-domains.pl --help`.

# A grant confines as on any row

Naming a group on the primary's row confines its members to the domains that
name it, as on any row: a manager whose group no domain named reached every
domain, and once only the primary's row names it, it reaches the primary only.
The operator group is never confined. t/unit/manager/426 holds both directions,
and that a manager confined this way can still take its group off the row.

# Tests

- t/unit/manager/426: on the manager API, a manager scoped to one domain is
  listed the primary only once the operator names its group on the primary's
  row; the bare line is written; a secondary with no access line shows none, on
  both listings; other keys and unknown names are refused; `domain_access_edit`
  on `(default)` and `''`; the confinement a primary-only grant makes.
- t/unit/manager/427: under node, the primary's sheet renders the two access
  fields and Save, and none of a domain's other fields, tools or delete.
