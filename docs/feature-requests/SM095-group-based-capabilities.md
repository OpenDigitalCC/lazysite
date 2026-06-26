---
title: "SM095 - group-based capabilities (attach permissions to groups)"
subtitle: "Grant partner capabilities to a group; members inherit"
brand: plain
---

::: widebox
Today the partner capabilities (WebDAV, manage content/themes/layouts/config,
sub-users) live on each **account**. The operator domain is already group-based
(`manager_groups` membership = operator). This item extends the *partner* domain the
same way: assign a capability to a **group**, and members inherit it - so partner
access can be managed by role instead of per-account.
:::

## Why

Raised alongside SM094: with many partner accounts sharing a role (e.g. several
"theme designer" connectors), per-account toggles are tedious and drift. Group-based
capabilities let an operator define a role once.

## Shape (sketch)

- A group may carry a set of capabilities (stored alongside the group, e.g. in
  `user-settings.json` under a `@group` key, or a new `groups-settings.json`).
- **Effective capability** of an account = its own grants ∪ the grants of every
  group it belongs to. Resolved in one place (`effective_settings` in the users
  tool) so every surface (manager-api `%need`, WebDAV `manage_*_for`, MCP `cap`)
  sees the union with no per-surface change.
- The manager Users/Groups UI gains per-group capability toggles; the per-account
  toggles remain (account grants on top of group grants).

## Open questions

- Storage location + format for group capabilities.
- Whether `ui` / interactive-login and `dav_scope` are group-assignable (probably
  not - those are account-shaped).
- Audit: a capability change on a group is a material event (who, which group, which
  capability).
- Interaction with operator bypass: operator (manager-group) status already grants
  everything in the manager domain; group capabilities matter for the partner domain.

## Status

Queued - design. Raised 2026-06-26. The enabler is that all surfaces already read
one `effective_settings`; this changes how that is computed, not the call sites.
