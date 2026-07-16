---
title: "SM155 - Group-level domain binding + preview + aliases"
subtitle: "The domain delegation binding moves from the account to the group; a pre-DNS preview; first-class aliases"
brand: plain
status: shipped
status-note: "delivered 2026-07-16 in 0.7.18; refines the SM154 domains admin from live-testing feedback"
---

# SM155 - Group-level domain binding

Live-testing SM154 (0.7.17) surfaced the real agency shape: a *team* manages a
sub-domain, so binding one account at a time (per-account `dav_scope` +
`home_domain`) was clumsy. SM155 moves the binding to the **group** and folds in
two other asks from the same session: a pre-DNS domain preview and first-class
aliases.

## Decisions

Binding location
: **Group.** A group carries `dav_scope` (content root) + `home_domain`
  alongside its capabilities. `group-add alice clienta-editors` both grants
  editing and confines Alice to clienta - one step. The per-account binding is
  **dropped** (nothing depended on it), a clean single-source model.

Multi-group scope
: **Union.** A member of several scoped groups may reach all their content
  roots (consistent with how capabilities already union across a user's
  groups). Enforced as "allowed if within ANY scope".

Preview
: A `domain-preview` action renders a domain's home page server-side under its
  own Host with auth cleared (anonymous public render), so an operator can
  prepare/debug a new domain **before** DNS/TLS is live.

Aliases
: A host that shares another registered domain's content root. `domain_add_alias`
  registers it (+ the canonical `site_url`); `domains-list` marks it `alias_of`
  the canonical; the UI groups aliases under it.

## How it works

Resolution mirrors the capability resolver exactly. `Lazysite::Auth::Settings`
gains `group_scopes(@groups)` / `group_home_domain(@groups)`; the processor keeps
the deliberate module-free copy (ADR 0001). `effective_settings` surfaces
`dav_scopes` (the union) so every channel reads a group-derived scope with no
per-channel group lookup. Enforcement uses `Common::outside_all_scopes` on the
manager-api (cookie + token), MCP and the processor; WebDAV's `scope_for` returns
the group scopes and `authorise` allows a path within any of them. Operators (no
scoped group) are unconfined.

## Set-up (the agency delegation, one team, one domain)

```
lazysite group-set clienta-editors manage_content on
lazysite group-set clienta-editors ui on
lazysite group-set clienta-editors dav_scope   content/clienta
lazysite group-set clienta-editors home_domain clienta.com
lazysite group-add alice clienta-editors        # confined + editing, in one step
```

The Groups page > Domain binding does the same in the UI. A member of
`clienta-editors` + `clientb-editors` manages both.

## Deferred

- The multi-domain **switcher** (a multi-group editor choosing which domain to
  view in the file browser) - confinement holds without it; the preview is the
  related, shipped piece.
- Per-alias presentation overrides (an alias currently inherits the canonical's
  content + site_url).
