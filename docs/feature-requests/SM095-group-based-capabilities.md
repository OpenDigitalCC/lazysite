---
title: "SM095 - group-based capabilities (permissions overhaul)"
subtitle: "One central resolver; explicit channel x action capabilities on groups"
brand: plain
---

::: widebox
Permissions move entirely onto **groups**. There is no special "manager" status
and no super-admin: an account's rights are the **union** of the capabilities of
the groups it belongs to, resolved in ONE place that every surface (manager UI,
control API, MCP, WebDAV) consults. Capabilities are explicit and total - a grant
means the same thing on every channel.
:::

## The model

Two kinds of capability, both stored on the group; you need **both** to act.

**Channel capabilities - WHERE you may operate** (each its own grant):

- `ui` - sign in to the Manager UI
- `webdav` - use the WebDAV transport
- `api` - use the control API (token / REST)
- `mcp` - use the MCP connector

**Action capabilities - WHAT you may do** (channel-agnostic):

- `manage_content`, `manage_nav`, `manage_forms`
- `manage_themes`, `manage_layouts`
- `manage_config` (incl. plugin enable/disable)
- `manage_users` (users + groups + sessions)
- `analytics` (visitor stats + audit)
- `create_sub_users` / `delegate_sub_user_creation` (the limited sub-tree
  delegation feature - kept distinct from `manage_users`)

**Rule:** an action over a channel is allowed iff the account's groups grant
`action` AND `channel`. e.g. publish a page over WebDAV needs `manage_content` AND
`webdav`; edit it in the Manager UI needs `manage_content` AND `ui`.

No `manager` flag, no `administrator` super-cap (it would become the dumping
ground for every "permission issue"). "Admin" is simply a group that holds every
capability. `manager_groups` in lazysite.conf is retired.

## Default groups (seeded)

| Group | Channels | Actions |
|-------|----------|---------|
| lazysite-admins | ui, webdav, api, mcp | all + sub-user delegation |
| content-editors | ui, webdav | content, nav, forms |
| design-team | ui, webdav | themes, layouts |
| agent-ai | webdav, api | content, nav, forms, themes, layouts, analytics |
| mcp-ai | mcp | content, nav, forms, themes, layouts, analytics |
| user-managers | ui | manage_users + sub-user delegation |

All editable on the Groups page; operators retune as needed.

## The central resolver

`Lazysite::Auth::Settings::caps_for($user)` returns `{ cap => 0|1 }` - the union
across the account's groups. Every surface consults it: the manager API `%need`,
the MCP `cap` check, the processor's UI page gating, and `lazysite-dav.pl` (which
used to read per-user settings on its own path - the gap that broke an earlier
clean-cut attempt). One implementation, one source of truth.

## Permission viewer

A read-only **channel x capability grid** for an account: channels across the top,
capabilities down the side, each granted cell tooltipped with the group(s) that
grant it. Shows derived rights; does not edit. Gated on `manage_users`. Collapsed
panel or modal on the Users page.

## Phasing

- **(a) DONE (0.5.14).** Central resolver `caps_for`; DAV + the users tool routed
  through it. Behaviour unchanged.
- **(b)** Add the channel caps (`ui`/`api`/`mcp`) + `manage_users` to the model;
  seed the six default groups; surface them on the Groups page; build the
  permission viewer. Additive / non-breaking (no new gate enforced yet).
- **(c) Clean cut.** Enforce channel + action gates from groups only; drop per-user
  capability honouring; remove the per-user toggles from the Users page (replaced
  by group membership + the viewer); retire `manager_groups`; migrate
  (lazysite-admins seeded with everything; operators assign the rest); rewire the
  test suite to grant via groups.

  **Scope discovered (attempted 2026-06-30, reverted):** the clean cut is bigger
  than a test rewire. Multiple surfaces still read capabilities DIRECTLY from
  `read_settings()->{$user}` rather than through `caps_for` - phase (a) routed
  only the DAV endpoint. The remaining direct readers found:
  - `cmd_account_create` sub-user gate (`create_sub_users` / `delegate_...`,
    users tool ~l.885).
  - The onboarding / partner brief generators (users tool ~l.1438, ~l.1794) that
    list a partner's caps from `$s->{...}`.
  - Likely the partner-create default-capability assignment.

  So (c) = (1) route EVERY cap reader through `caps_for` (a small but careful
  sweep); (2) redesign partner/sub-user onboarding so a new partner gets caps by
  GROUP assignment, not per-user defaults (the "partner has webdav by default"
  behaviour goes away); (3) drop the webdav->content / content->nav,forms
  inheritance (groups are explicit); (4) deep test rewiring (the broad churn:
  ~33 files - DAV cluster was already done and is mechanical; the manager/users
  cluster needs per-test thought for the whoami-groups assertions, the removed
  inheritance, and the new partner model). A focused session, not a tail-end push.

## Migration (clean cut, no hidden debt)

On upgrade, `lazysite-admins` is seeded with ALL capabilities so the operator
keeps full access and configures everyone else from the Groups page. Per-user
grants stop being honoured at phase (c). Acceptable for the ~14 live sites (manual
fix-up); would need an auto-migration at tens of sites.

## Status

(a) shipped 0.5.14. (b) + (c) in progress, same session.
