---
id: SM1135
title: "SM1135: a directory group grants manager capabilities only when the operator marks it"
subtitle: "Every capability gate asks one rule: a group a trusted proxy names grants its capabilities, and operator status, only if its record carries directory_grants, which only the operator sets."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: united/platform project, planned in SM1128 (P1-6), ruled by the release manager 2026-10-17 "rulings as proposed" (R1)
area: auth
status-note: "SHIPPED on n632 (claude/n632-a-marked-directory-group-grants): Auth::Settings::request_cap_groups and request_group_caps; t/integration/271."
---

# What happened

SM1128, "What the code does today", item 1:

> **Groups under `auth_proxy_trusted`.** Page gates (`auth:`, `auth_groups:`,
> `groups:`) and per-file ACLs use the groups the proxy sends [...]. Manager
> capabilities do not: `caps_for` reads the local account store, so a directory
> group grants a capability only through the few gates that also read the header
> (`ui`, `manage_content`, `/manager` entry, operator status).

the plan, P1-6:

> Capabilities from header groups, consistently (R1): `caps_for` answers from the
> request's groups when the identity came from the proxy.

and the ruling, R1:

> Should a directory group grant manager capabilities, or only page and file
> access? Page and file access by default; capabilities only for groups the
> operator marks.

So there were two answers to "what may this request do". The gates that read the
request's groups (`ui` and `manage_content` in the manager API, `_is_manager` in
the processor, `_is_operator` in the ACL code) believed any group name the proxy
sent that happened to match a lazysite group, with no mark; every other gate
(`_user_caps`, which feeds the per-action capability checks) read the local
store, where a directory user has no account, and so answered nothing. A lazysite
group called `staff` holding `manage_config` was handed to everyone the
directory put in `staff`.

# What shipped

A group record in `groups-settings.json` may carry `directory_grants: true`.
`Lazysite::Auth::Settings::request_cap_groups($identity)` is the one rule: for an
identity whose source is `proxy` (the one reader, `request_identity`, SM1131) it
keeps only the groups so marked; a cookie or direct identity passes whole, so the
cookie path is unchanged. `request_group_caps` is the union of what the marked
groups hold, through the nesting closure.

Every gate asks it:

- the manager API's `ui` and `manage_content` gates;
- `Manager::Common::_user_caps`, which now adds a marked group's capabilities to
  the account's own for the caller, so each per-action capability check agrees
  (a proxy user with no account holds `manage_content` through a marked group);
- `Auth::Acl::_is_operator`: operator status from a header group needs the
  operator group (the `manager` flag) marked as well;
- the processor's manager entry and admin bar (`_is_manager`, the nav
  capabilities), through `_cap_groups`, the module-free copy ADR 0001 records;
- the data endpoint's write capability (SM1137).

Setting the mark is the operator's alone (`tools/lazysite-users.pl`,
`group-settings-set directory_grants`): `local`, a member of the operator group,
or anyone on an unsecured site. A `manage_users` holder is refused (SM991), and
the change is audited as `key directory_grants=on|off` on both doors. The Groups
page shows a tick, to the operator only (`group-settings-get` answers
`viewer_operator`), with a note saying what it does. `group-set GROUP
directory_grants on` is the shell spelling.

Tests: t/integration/271 through the real CGIs. A marked group grants `ui` (the
manager entry and API) and `manage_content`; an unmarked group of the same name
opens an `auth_groups` page and nothing in the manager; an unmarked operator
group is not operator and a marked one is; the cookie path with the same unmarked
group still opens the manager; a `manage_users` holder cannot set the mark and the
operator can. Each fix was put back to its earlier version in turn and the test
went red. t/integration/265 now marks its directory group.
