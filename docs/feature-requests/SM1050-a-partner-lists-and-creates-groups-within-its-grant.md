---
id: SM1050
title: "SM1050: a partner lists and creates groups within its grant"
subtitle: "groups-list and group-set on the control API, list_groups and set_group on MCP: a manage_users holder sees the groups (a confined one, those relevant to its domains) and creates a group with capabilities it holds, never the operator flag."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox 2026-10-12, what a site partner cannot do while building a site (P-1, P-2, P-3)
area: security
status-note: "SHIPPED (PENDING): groups-list / list_groups and group-set / set_group behind manage_users on one module (Manager::Groups); a confined caller sees its domains' allowed groups, its own and the ones it created, and changes only the ones it created; only held capabilities are granted; never the operator flag; audited (t/integration/209)."
---

# The report and the ruling

P-1 "Create a group", P-2 "See which groups exist", P-3 "Set what a group may
do": `principals` and `users` are cookie-only, and `whoami` lists only the
caller's own groups, so a partner could neither tell a typo from an absent group
nor provision a site's roles (`authors`, `editors` with `webdav` and
`write_data`; `account-approvers` with `manage_users` and `read_submissions`).

The release manager, 2026-10-12, in their words: "Yes, within the delegation
limit": `groups-list` (read-only, any manage_users holder: names, capabilities,
member counts; a domain-confined caller sees only groups relevant to its
domains) and `group-set` behind manage_users: create a group and grant only
capabilities the caller holds AND may grant (the existing delegation limit /
SM195 ceiling); NEVER the operator flag; audited; MCP twins (SM943 one
declaration). Use the same group-existence definition as n510's SM1045 union.

# What was built

One module, `Lazysite::Manager::Groups`, which both doors call with who is
asking (account, the capabilities it holds on that door, whether it is
domain-confined, whether it is the operator):

| Control API | MCP | Gate | Does |
| --- | --- | --- | --- |
| `groups-list` (GET) | `list_groups` | manage_users | each group: name, label, the capabilities it turns on, the accounts directly in it, whether it is the operator group, `yours` when the caller created it |
| `group-set` (POST, body `group`, `caps`) | `set_group` | manage_users | creates the group if it does not exist, then turns each named capability on or off |

## Which groups a confined caller sees

A group is relevant to a domain-confined caller (every token and MCP grant, and
a cookie manager whose groups bind a domain) when:

1. a domain it reaches (`caller_may_reach_domain`) names the group in its
   `allowed_groups`;
2. it is a member of the group, directly or through nesting
   (`Settings::effective_groups`); or
3. it created the group with group-set (`created_by` on the group's record).

Nothing else: not another domain's groups, not the operator group unless one of
the three names it, not a group another account created. An unconfined caller
(the operator, a cookie manager bound to no domain) sees every group.

## What group-set may do

- **Exists** means SM1045's union: a name in `groups-settings.json` or in the
  groups file - `Settings::group_names`, which Manager::Groups asks (as acl-set
  and SM1016's allowed_groups check do); the users tool's group-create asks the
  same union.
- **Never the operator flag.** `manager` (the operator group's flag, SM991) or
  `operator` in `caps` is refused, to everyone, the operator included.
- **The operator group** is changed only by the operator.
- **A confined caller** changes only the groups it created, and creates new
  ones; any other existing group is refused (another domain's, the instance's).
- **The delegation limit.** A capability is turned on only if the caller HOLDS
  it on this door (the token's grant, the cookie account's capabilities); the
  users tool, the store's owner, then applies SM195's ceiling again with the
  caller as `actor`. Turning a capability off needs neither.
- **Validated whole first**: an unknown capability, a bad value, a capability
  not held or the operator flag refuses the request and nothing is written.
- **It does not add members.** Membership stays the users tool's, through the
  manager, and its ceiling (SM268 H8) is unchanged.
- **Audited**: one row, action `group-set`, target `@group`, detail what changed
  (`created +webdav,+write_data`, `-write_data`).

`group-create` in the users tool records `created_by` when group-set passes it;
the cookie `users` action strips a `created_by` a caller sends, so no caller can
name another account as a group's creator and hand it the group.

# A risk recorded, not changed

A group carries capabilities instance-wide; what confines a member is the
domain that names the group in `allowed_groups`. A member of a group no domain
names is an unbound account (SM976 R2: unconfined on the cookie door; an unbound
WebDAV account reaches the primary's content). group-set cannot put anyone in a
group, so it widens nothing by itself; but the person who later adds members to
a partner's group should know that the group binds a domain only if a domain
names it. Naming it in the partner's domain (`domain-set allowed_groups`, which
needs manage_users, SM647) is the step that confines its members.

# Tests

t/integration/209: a confined token lists its domain's groups and its own, not
another domain's; the operator and an unbound cookie manager list every group;
the token creates `authors` with webdav and write_data (stored, `created_by`,
audited) and revokes one; refusals - a capability not held (nothing created),
the operator flag (to the operator too), another domain's group, the operator
group, its own group it did not create, a bad name, an unknown capability;
a cookie manager grants only what it holds; the MCP twins answer the same; a
cookie `group-create` cannot plant a creator. Sabotage: four guards removed in
turn (relevance, the holds check, the confined-change check, the operator flag),
each fails the test.

Lints updated with the change: t/lint/14 (groups-list a reviewed cookie read),
98 (110 token actions), 91 (`group`, `caps` are not paths), 218 (group-set
excepted from instance-wide, with the ruling). The bench baseline's users tool
statement count (the created_by option, +2) is re-measured once at the stack's
tip, with SM1053's growth (`account-approve`'s groups list, +2): 3,423.
