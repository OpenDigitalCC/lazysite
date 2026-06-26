---
title: "SM094 - Users page: permission clarity + UX"
subtitle: "Show only what's relevant; make the operator-vs-partner model legible"
brand: plain
---

::: widebox
The per-account capability toggles (WebDAV, manage content/themes/layouts/config,
sub-users) gate the **partner** surfaces (token / WebDAV / MCP) only - a member of a
`manager_groups` group is a full **operator** and bypasses them entirely (verified:
the `%need` capability gate is inside `if ($token_auth)`; `_is_operator` is true for
manager-group members). The Users page shows the toggles on every account, which
reads as if they gate a manager - they don't. This item makes the page show only
what applies.
:::

## Background (the model, confirmed in code)

- **Operator / manager domain (browser cookie):** membership of a `manager_groups`
  group = operator = full manager UI access, and bypasses per-file ACLs **and** the
  capability toggles.
- **Partner / publishing domain (token, WebDAV, MCP):** never an operator; confined
  by exactly those capability toggles + per-file ACLs.

So the toggles only ever govern a token/partner. On a manager-group account they are
inert.

## Changes

1. **Hide capabilities when an inherited role overrides them (the user's ask).**
   When an account is in a `manager_groups` group, replace the Access capability
   checkboxes with a note: *"Administrator via group `<g>` - full access; per-account
   capabilities below apply only to token / WebDAV / connector use."* Needs the page
   to know `manager_groups`: expose it in `action_whoami` (add `manager_groups`) and
   fetch once at load.

2. **Relabel the capability section** from a bare list to **"Publishing access
   (WebDAV / control API / AI connector)"** so it is obvious these are partner
   grants, not manager rights.

3. **Hide unused credential controls for AI/backend accounts (the user's ask).** An
   AI account (`ui` off, token auth) does not use the interactive-login credentials.
   For such accounts hide the Password, Setup-link and Two-factor rows of the
   Credentials section; keep the **Token** (Generate credential) row, which is what
   they do use. (A human account keeps the password rows; the token row stays for
   both.)

4. **Collapse sub-users under their parent (the user's ask).** Accounts with a
   recorded parent (`created_by`/`managed_by`) are currently listed flat,
   alphabetically. Render them nested and collapsed beneath their owning account, so
   the hierarchy is visible. Re-key the `renderUsers` walk into a parent -> children
   tree; children keep their own `<details>` rows, indented under the parent.

## Status

Raised 2026-06-26. Items 1-4 are bounded Users-page (`starter/manager/users.md`)
changes plus a one-line `action_whoami` addition for item 1. The broader "attach
capabilities to groups" is its own item, [[SM095]].
