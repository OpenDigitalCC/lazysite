# 0003 - Capabilities are channel x action, carried by groups only

Status: Accepted
Date: 2026-07-02 (retrospective; shipped as SM095, 0.5.15-0.5.25)
Tags: auth, capabilities, groups, sm095

## Context

Access rights had accreted per-account boolean flags plus an implicit
"manager" status from `manager_groups` membership. Grants were invisible
("hidden grants"), inconsistently enforced across the four surfaces (manager
UI, control API, MCP, WebDAV), and impossible to reason about: the operator
could not answer "who can do what, where".

## Decision

A capability is the conjunction of a **channel** (WHERE you may operate: ui,
webdav, api, mcp) and an **action** (WHAT you may do: manage_content, nav,
forms, themes, layouts, config, users, analytics, audit, create_sub_users,
delegate_sub_user_creation). Capabilities are carried **only by groups**
(`groups-settings.json`); an account's rights are the union across its groups.
There is no per-account grant, no inheritance between capabilities, and no
implicit manager status: Manager-UI access is the `ui` channel capability and
unrestricted user administration is `manage_users` (the old `manager_groups`
config survives only as a backend fallback, not editable in the UI). Every
surface resolves through `Lazysite::Auth::Settings::caps_for` (see ADR 0001
for the one recorded local copy).

## Rationale

The operator's stated principle: "much prefer to know that a permission is
explicit and total." Groups-as-roles make grants visible, auditable and
editable in one place; the channel x action split lets an AI partner hold
webdav+content without ui, and a human editor hold ui+content without api.

## Consequences

- The permissions grid (Users page + `lazysite-users.pl permissions`) can
  derive the full picture mechanically.
- A clean cut was chosen over honouring legacy per-account grants; the
  one-off migration report (2026-07-01) surfaced orphaned grants for manual
  fix-up.
- New capabilities are one `@CAP_KEYS` entry + a group toggle, not a schema
  change.
