---
id: SM1371
title: "SM1371: agent accounts hold roles"
subtitle: "Ruling 122, the first step of simplifying permissions: four agent roles ship as groups, whoami and the account view name the roles held and any capability beyond them, a grant that needs an extension offers its enable, and manage_forms reaches a form's own configuration on every door."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager, ruling 122 (0.16.6 brief n758)"
area: auth
status-note: "SHIPPED on n758: four agent roles seeded and adopted once; Auth::Settings::role_summary in both whoamis and users-page; Groups page offers the extension enable; Files admits lazysite/forms/<name>.conf to manage_forms."
---

# What was asked

Ruling 122. On real sites, every permissions change was a capability grant to
an agent account - `analytics`; `manage_data` + `write_data`;
`read_submissions`; `manage_briefs` - or `auth: required` on a page. Over-grants
went unnoticed; a WebDAV-only grant got 403 on `lazysite/forms/<name>.conf`;
granting data needed a separate extension enable. The first step:

- roles for agent accounts, named bundles built on groups (ADR 0003), not a
  second permission system;
- `whoami` and the manager's account view show the role held and any
  capability beyond it;
- a grant that needs an extension names it, and the manager offers the enable
  in the same step, explicit and audited;
- `manage_forms` covers a form's own `.conf` for writing.

# Change

## Four agent roles, as groups

Shipped as assignable groups in `_default_group_seed` (tools/lazysite-users.pl),
each over MCP, each one job, composable:

| Role group | Label | Capabilities | From the measured grants |
|---|---|---|---|
| `content-agent` | Content agent | `mcp`, `manage_content`, `manage_nav`, `manage_forms` | `cap-content`'s set: pages, navigation, forms (and with SM1371 a form's own config) |
| `data-agent` | Data agent | `mcp`, `manage_data`, `write_data`, `manage_briefs` | `manage_data` + `write_data`; `manage_briefs` as `cap-data` pairs it |
| `forms-reader` | Forms reader | `mcp`, `read_submissions` | `read_submissions` |
| `analytics-agent` | Analytics | `mcp`, `analytics` | `analytics` |

None carries `ui`, `api`, `webdav`, design, settings, people or audit. The
capabilities sit on the role record (as `lead-readers`' do) rather than through
`cap-*` nesting. A site seeded before them adopts them once, at the users
tool's next ordinary use (`_adopt_agent_roles`, beside SM1241's bundle
adoption): only on a site with the shipped role layer, only a role that is
absent, never rewriting one that exists, recorded in `bundles-adopted.json` so a
role an operator deleted stays deleted, and with NO MEMBERS - adopting a role
gives nobody anything.

## The role held, and what is held beyond it

`Lazysite::Auth::Settings::role_summary($user, $held)`: the roles are the
account's direct groups that are assignable and grant at least one capability
through their nesting closure, less the account's own `role-<account>` group
(where `partner-create` and one-account grants keep capabilities); `beyond` is
every capability the account holds that no role grants. So an account whose
grants all sit on its own group reports them all beyond its roles, which is the
over-grant the evidence found unnoticed.

- Both whoamis carry it as `roles: { roles: [ { group, label, capabilities } ],
  beyond: [...] }`, from `Lazysite::Capabilities::whoami_roles` (one builder,
  SM288), beside SM1370's `grant` block.
- The Users page row (users-page, the account view) shows each role as a tag,
  its capabilities on hover, and `+N beyond role(s)` with the capabilities
  named.

## A grant that needs an extension offers its enable

The capability map the Groups page reads (`channel-services`,
`capability_extension`, SM675) now carries the owning extension's `script`.
Ticking a capability whose extension is off asks: "manage_data needs the Data
tables extension, which is switched off - the grant does nothing until it is
on. Enable it now?" Answered yes, it calls `extension-enable` with that script:
`manage_config` is still required for it, and it is audited as every extension
switch is. Answered no, the grant stands and the grid keeps its dormant mark.

## manage_forms reaches a form's own configuration

WebDAV has admitted `lazysite/forms/<name>.conf` to `manage_forms` since 0.8.1.
The other file doors - MCP `read_file`/`write_file` and the manager's file
editor (`read`, `save`) - refused it to every grant as "inside the reserved
lazysite/ tree". They now admit it to `manage_forms`:

- `Manager::Common::carveout_requirement` names it, so both dispatchers' carve-out
  gate requires `manage_forms` for it (`form_conf_name`);
- `Manager::Files::action_read`/`action_save` answer it themselves from
  `$CALLER_CAPS`, set by each dispatcher, so a verb that reaches the choke point
  without that gate cannot open it;
- a write meets WebDAV's rules: UTF-8 text, targets naming existing handlers only
  (`Handlers::form_conf_problems`), a confined caller reaching the form
  (`form_reach_refusal`) and binding only handlers it may use
  (`handler_bind_refusal`);
- `smtp.conf`, `handlers.conf` and `schedule.conf` are not forms and stay
  refused.

A WebDAV-only grant still gets 403 on a form's config: `webdav` is the door, and
the file is `manage_forms`'. The content-agent role carries `manage_forms`, so an
agent given that role reaches it.

# Choices made

- **Capabilities on the role record, not through bundles.** An existing site
  adopts a role as one new record; nesting it in `cap-content` or `cap-data`
  would change the membership of a bundle other roles draw on.
- **MCP only.** The agent roles carry `mcp` and no `api` or `webdav`: the agent
  surface is MCP, and the control API and WebDAV are for scripts (`ch-script`).
  An operator wanting either adds it, and it shows as beyond the role.
- **`manage_briefs` is in the data agent**, following `cap-data`'s pairing of
  briefs with data, so the content agent stays exactly `cap-content`'s set plus
  `mcp`.
- **A group that grants nothing is not reported as a role** (an organisational
  or page-access group), and the account's own `role-<account>` group is not a
  role.
- **The role summary is the account view**: no address rule is applied. The
  request view stays `capabilities`, which a narrowing applies to.
- **The extension enable is offered, not done.** It is a confirm after the grant
  is saved, and a separate audited call that needs `manage_config`; nothing is
  enabled as a side effect of a grant.
- **A form config is refused when the dispatcher said nothing.** `$CALLER_CAPS`
  undef - an unsecured site, where the carve-out gate is skipped - refuses it, as
  before this change; WebDAV is unchanged.
- **Only read and save.** Delete, move, copy and upload of a form config stay
  blocked; `delete_form` removes a registration.

# Tests

- t/unit/users/70-agent-roles-are-groups.t: the four roles seeded with exactly
  their capabilities; adopted once, empty, on an existing site, and a deleted one
  not brought back; users-page's roles and `beyond`; a role drawing on bundles.
- t/unit/manager/460 subtest 4: the `roles` block on both whoamis.
- t/unit/manager/461-manage-forms-covers-a-forms-own-conf.t: MCP and the manager
  editor, refused without `manage_forms`, admitted with it, the binding rules,
  the three non-form files.
- t/unit/manager/462-a-grant-names-the-extension-it-needs.t: the map's `script`,
  and the Groups page's offer.

Each fails with the change reverted (run against b7f178856).
