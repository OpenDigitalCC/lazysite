---
id: SM1387
title: "SM1387: a group is deleted once nothing uses it, on every door"
subtitle: "No token or MCP surface deleted a group, and the manager's delete looked only at members. group-delete, delete_group and the Groups page now refuse while the group holds a member or anything names it, saying what; the operator group is never deleted."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent (0.16.7 small fixes)"
area: auth
status-note: "SHIPPED (PENDING) on n764: Manager::Groups::group_delete behind control API group-delete and MCP delete_group; the users tool's group-delete asks Lazysite::Auth::GroupRefs and refuses the operator group. t/integration/357."
---

# What happened

A group could be created and changed over the control API and MCP (SM1050,
`group-set`, `set_group`), and not deleted: a partner provisioning a site's
roles left every experiment behind. The manager's Groups page deleted through
the users tool's `group-delete`, which refused a group with members (and the
last operator group) and nothing else - so an empty group a page, an access
rule or a domain still named was deleted, the rule then admitted nobody through
it, and a group made later under the same name would have inherited its grants.

# What shipped

**One action, three doors.** Control API `group-delete` (`group` in the body,
`manage_users`, mutating, destructive, access-changing, audited with the group
as `@group`), MCP `delete_group` (its twin, on `Manager::Groups::group_delete`),
and the manager's Groups page, whose Delete now calls `group-delete`.

**Refused while anything uses it**, naming what (`kind: in-use`):

- a member, account or nested group (`members`, the first five named);
- anything that names it (`references`, `Lazysite::Auth::GroupRefs`): a page's
  `auth_groups`; an `acls.json` rule's `read` or `write` `@group`; a domain's
  `allowed_groups` or `locked_groups`, the primary's or an alias's; lazysite.conf's
  `auth_group_map`; a data table's `writable_by`; an Odoo binding's `callers`
  (handlers.conf); a connector's `callers` (connectors.json); odoo.conf's
  `odoo_group_map`. A store that cannot be read refuses too, naming it.

The walk runs in the users tool, the store's owner, so the Groups page's old path
through `action=users` is held to the same rule.

**Not counted**: the group's own record and membership (deleted with it), its
name in another group's member list (un-nested, as since N141B-E: it is empty, so
nothing it passed on is lost), `bundles-adopted.json` (kept, so a deleted shipped
group stays deleted), sign-in sessions, and the retired `manager_groups` key (the
users tool migrates it to the operator flag on first use, and the operator group
is never deleted).

**Which groups may go.**

- The operator group (the `manager` flag, or nested into one) is never deleted,
  by anyone, the only one or not (SM991).
- An empty agent role (SM1371) may be: `_adopt_agent_roles` records it as had, so
  it stays deleted. So may any other shipped role or bundle once empty and
  unreferenced; `reset-groups` restores a shipped one.
- A domain-confined caller (every token and MCP grant, a confined manager)
  deletes only a group it created with `group-set`, as it changes only those.

# Tests

t/integration/357: the operator over the control API deletes an empty group (the
audit row names `@spare`) and gets not-found the second time; a group with a member
is refused naming the member and deleted once empty; each of twelve references
(page flow and block lists, acl read and write, alias allowed_groups and
locked_groups, the primary's allowed_groups, auth_group_map, writable_by, an Odoo
binding's callers, a connector's callers, odoo_group_map) is refused naming the
place, and the group is deleted once the reference is removed; the operator group
is refused to the operator; an empty agent role is deleted; a confined token and
an MCP grant delete a group they made and are refused another; an account without
manage_users is refused. With the users tool as on main every reference subtest
fails.
