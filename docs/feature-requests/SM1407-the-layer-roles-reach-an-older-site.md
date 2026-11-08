---
id: SM1407
title: "SM1407: analysts and lead-readers reach a site bootstrapped before them"
subtitle: "The two roles shipped with the bundle layer in the seed only, and no adoption named them, so an older site never got them while the agent roles and the bundles arrived. They are adopted once, with no member, where the bundle layer is there, and never on a store whose seed already wrote them."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent, from edge testing of 0.16.7 (T-103, brief n774)"
area: users
status-note: "SHIPPED (0.16.8) on n774: _adopt_layer_roles in tools/lazysite-users.pl, before _adopt_added_bundles. t/unit/users/74. SECURITY.md entry drafted. UPGRADE.md note under Unreleased (0.16.8)."
---

# What happened

On the 0.16.7 edge run (T-103, R9 W1) the four agent roles arrived after the
Groups and Users pages were opened; `analysts` and `lead-readers` did not.
`_adopt_added_bundles` adopts the groups `_default_group_nesting` lists as
bundles (cap-tidy, cap-services, cap-maintenance, cap-audit-switch, ch-files and
the rest), and `_adopt_agent_roles` the roles marked `agent_role`. The two
roles are in `_default_group_seed` only, which runs where the group settings
file is absent, so a site bootstrapped before the seed had them never gets
them. SM1393 fixed the guard both adoptions share, not this list.

The brief calls them the 0.16.0 bundles. `git log -S"'analysts'"` names one
commit, 45a44eaf9 (SM628-SM631, first in 0.11.2): they are roles, not bundles,
and they shipped with the bundle layer itself. They draw their grants through
it: `analysts` sits in cap-analytics, cap-audit and ch-ui; `lead-readers`
holds `read_submissions` itself and sits in ch-script.

# The change

`_adopt_layer_roles` runs in `_ensure_groups_seeded` before
`_adopt_added_bundles`. It adopts each of the two by the agent roles' rules
(SM1371, with SM1393's guard): a bootstrapped site (`_bootstrapped`), an absent
role only, never rewriting one that exists, with NO MEMBERS so nobody's access
changes, and once - the name goes into `bundles-adopted.json` (SM1262), so a
deleted one never returns, and a record that cannot be read adopts nothing.

Two rules more, because these are roles of the bundle layer:

- Only where the bundle layer is there (a shipped bundle present, as
  `_adopt_added_bundles` asks). Without it `analysts` would be a role that
  grants nothing to the account put in it; t/unit/users/72's site with no role
  layer still gets the agent roles and neither of these.
- Each adopted role is nested into the shipped bundles present that list it,
  as a new install nests it. cap-audit, which only `analysts` draws on, is
  absent on such a site because no shipped role drew on it; running first
  lets `_adopt_added_bundles` adopt it with `analysts` inside.

And one guard the agent roles do not need: never on a store whose manager
group carries the `seeded` mark (`_store_marked`, the reading `_shipped_groups`
already made). The mark arrived in 0.11.3 (SM608), after these roles, so the
seed that wrote the mark wrote them; absent there means an operator deleted
one before the had-record kept deletes, and it is recorded as had and left
deleted. On a store with no marked manager group absent says nothing, and the
role is adopted. The edge store is such a store (SM1393).

# What appears on an older site

On the next Users or Groups page load (or any users-tool command that seeds
first), where the site has the bundle layer and no marked manager group: the
roles it lacks of `analysts` and `lead-readers`, with no members, nested into
their bundles, and cap-audit with them if it was absent. The audit log records
each ("role added for this release (SM1407)").

# Tests

t/unit/users/74-the-layer-roles-reach-an-older-site.t, in the style of
t/unit/users/72: a store from before the two roles gains both on first use, as
shipped, with no member, each bundle drawing on what a new install nests in it,
cap-audit adopted, the record remembering both and a second use changing
nothing; a role the had-record names does not come back, nor one an operator
deletes after adoption; on a marked store neither is adopted and both are
recorded as had; a site without the bundle layer gets neither. With the change
reverted subtests 1 to 3 fail. t/unit/users/72 passes unchanged.

# Upgrade

Nothing to do but the upgrade. UPGRADE.md says what appears, under Unreleased
(0.16.8).
