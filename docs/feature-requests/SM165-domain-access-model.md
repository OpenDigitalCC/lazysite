---
title: "SM165 - Domain access-control model (allow-list + user locks)"
subtitle: "Domains own who may manage them; per-user locks confine; sub-users never exceed their creator"
brand: plain
status: shipped
status-note: "signed off 2026-07-18; targeted at 0.7.26. Re-architects SM155 domain binding. Edge-only, no migration."
---

# SM165 - Domain access-control model

## Why

SM155 (0.7.18) put a `dav_scope` (content-root path) and `home_domain` on each
**group**, and that one field does two jobs at once - it both **allows** a domain
and **confines** members to it. Live-design surfaced the problems:

- **Conflation.** Adding a general editor to `clienta-editors` does not just
  grant clienta; it silently *restricts* them to clienta. Allow and confine are
  different intents and should be separate controls.
- **Wrong home for the data.** A domain has no idea who may edit it - the link
  runs backwards and indirectly (a group stores a content-root *path*, so
  "who can edit clienta?" needs a scan of every group). Access to a domain
  should be visible *on the domain*.
- **Re-typed content root.** The group's `dav_scope` duplicates a value the
  domain already owns (`content_root`), so the two can drift.
- **No per-user confine.** You cannot lock one contractor to one domain without
  making a bespoke single-member group.

This spec moves access **onto the domain**, splits allow from confine, and adds a
creator ceiling so delegated agents can never out-reach their maker.

## Model

Three entities, two relationships.

Entities
: **Domain** (a host + its content root + presentation, in `lazysite.conf`);
  **Group** (capabilities + membership); **User** (belongs to groups; may create
  sub-users).

Allow (additive, on the domain)
: A domain names the **groups** that may manage it. A user is *allowed* a domain
  when they belong to one of its allowed groups. Many groups per domain, purely
  additive - no conflict.

Confine / lock (subtractive, on the domain, per user)
: A domain may also name **users** who are *locked* to it. A locked user can
  reach only the domain(s) they are locked to (intersected with what their groups
  allow) - never the wider site.

Both live on the domain, so the Domains page shows the whole access picture in
one place: *groups that manage this site* + *users locked to this site*.

## Storage

The domain record (per host, in `lazysite.conf`, alongside the existing
`alias.<host>.*` keys - and the base keys for the default site):

```
alias.clienta.com.content_root:   sites/clienta
alias.clienta.com.allowed_groups: clienta-editors, agency-leads
alias.clienta.com.locked_users:   alice, clienta-bot
```

- `allowed_groups` - comma list of group names permitted to manage this domain.
- `locked_users` - comma list of accounts confined to this domain.
- `content_root` stays the single source of the domain's root; nothing is
  re-typed elsewhere.

The group's `dav_scope`/`home_domain` (SM155) are **removed**. `home_domain`
becomes *derived*, not stored (see Resolution).

## Resolution

For a user `U` with groups `G(U)` (compound-expanded - see below):

allowed(U)
: `{ D : allowed_groups(D) ∩ G(U) ≠ ∅ }` - the domains whose allow-list includes
  one of U's groups. Empty ⇒ U is a general editor (the default host / whole
  content namespace), exactly as an unbound user is today.

locked(U)
: `{ D : U ∈ locked_users(D) }`.

effective(U)
: `allowed(U)` when `locked(U)` is empty; otherwise `allowed(U) ∩ locked(U)`. A
  lock **narrows**, never grants. Multiple locks intersect to their union of
  locked domains - still a narrowing, so no conflict.

home / rooting
: the single element of `effective(U)` if there is exactly one; else empty (the
  SM157 domain switcher offers the set). No stored `home_domain`.

The effective set is expressed as the same **content-root scope list** SM155
already feeds every channel (each domain contributes its `content_root`), so the
enforcement code is unchanged - only the *source* of the list moves.

## Sub-user ceiling

A created account must never out-reach its creator. Enforced as an intersection
up the `created_by` chain, at resolve time (not just at creation, so later config
drift cannot lift the ceiling):

: **effective_scope(U) = own_effective(U) ∩ effective_scope(creator(U))**,
  recursively, terminating at a top-level (creator-less) account.

The companion rule for capabilities: **caps(U) ⊆ caps(creator(U))** - a user
cannot grant a sub-user a capability they do not hold. Both are checked at
account-create / group-add time (fail closed with a clear message) *and* capped
at resolve time.

This makes the delegated-agent case safe by construction: a user who spins up an
MCP agent (a machine sub-user) yields an agent confined to a **subset** of the
user's own domains and capabilities - it can never see a domain, or do a thing,
the creator cannot.

## Enforcement - every channel (unchanged points)

`effective(U)` feeds the existing confinement checks, so a lock holds however the
user connects:

- **Manager UI** (cookie) and **control-API token** - `_confine_scope` /
  `outside_all_scopes`.
- **MCP** - the tool-dispatch scope check.
- **WebDAV** - `scope_for(user)` + `authorise(...)`.
- **Processor** - roots/limits the render and the file browser.

No new enforcement surface; the model only changes how the scope set is computed.

## UI

Domains page (owns access)
: Per domain: an **allowed-groups** multi-select (registered groups) and a
  **locked-users** picker (accounts). This is where a domain's team is set.
  Needs `manage_domains`.

Groups page
: The Domain-binding section is **removed** (no more `dav_scope`/`home_domain`
  free-text). A group optionally shows, read-only, which domains list it in their
  allow-list ("manages: clienta.com, clientb.com").

User (account) page
: Shows, read-only, the user's effective domains and any lock ("locked to
  clienta.com - set on the Domains page"), mirroring how group-derived scope is
  shown read-only today. The creator ceiling, if it narrows the user, is noted.

## Compound groups (forward-compatibility)

`allowed_groups` names groups; whether a user is "in" an allowed group is a
**membership-resolution** question. Compound groups (group-of-groups, in
`BACKLOG.md`) expand there - `G(U)` becomes the transitive closure of a user's
direct groups. The domain never needs to know. So this model is compound-ready
with no change to the domain record; building compound groups later (or in
0.7.25) only touches the membership resolver.

## Migration

**None.** SM155's per-group `dav_scope`/`home_domain` are edge-only (introduced
0.7.18; production is on 0.7.13). The fields are dropped and replaced by the
domain-side `allowed_groups`/`locked_users`. New installs start on the new model.

## Decisions (signed off 2026-07-18)

Single write surface
: The **Domains page is the only place access is edited**. The Groups and User
  (account) pages **mirror it read-only** - one source of truth, no write-through
  from elsewhere.

Empty allow-list = operator-only
: A **non-default** domain with an empty `allowed_groups` is **operator-only** -
  no delegated group can manage it until one is added (explicit is safer than
  "any manager can"). The default site is unaffected (general editors manage it
  as today).

## Out of scope

- **Per-path (sub-folder) confinement** below a domain's content root - the lock
  is domain-granular. A finer grain is a later item if it is ever needed.

## Tests

- Resolution unit: allowed / locked / effective across single + multi group,
  lock-narrows, lock ∩ allowed, empty-lock, general-editor (no allow).
- Ceiling unit: sub-user never exceeds creator (scope + caps), multi-level chain,
  resolve-time cap even when own config would exceed.
- Enforcement, per channel: a locked user is confined over UI, token, WebDAV and
  MCP (extend the existing SM155 confinement tests to the new source).
- Compound: `G(U)` transitive closure feeds allowed(U) (once compound lands).
- Docs/consistency: capability-map + describe_capabilities reflect the model.
