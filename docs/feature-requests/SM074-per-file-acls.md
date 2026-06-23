---
title: "SM074 - Per-file ownership and ACLs"
subtitle: "Opt-in owner + read/write lists in a central store, enforced at the WebDAV and manager layers"
brand: plain
---

::: widebox
A file's access can be narrowed by an entry in a **central ACL store**
(`lazysite/auth/acls.json`) naming its **owner** and optional **read** / **write**
allowlists. With no entry, access is unchanged (the existing per-account scope).
With one, only the owner and the listed users may read or write the file - so
several authors can share one WebDAV scope without overwriting each other's
pages. ACLs are managed through API actions, never per-file sidecars, so the
content tree stays clean.
:::

## 1. Summary

WebDAV access today is per-account: a partner's `dav_scope` confines it to a
subtree, but within that subtree any writer may overwrite any file. For
multi-author sites, an author wants to **own** their pages - others may see the
published result, but not modify the source. SM074 adds an opt-in per-file ACL:
an entry in one central JSON store recording an `owner` and optional `read` and
`write` allowlists, enforced at both the WebDAV and manager layers.

The store is a single file, not a litter of sidecars: ACLs are metadata (unlike
a `.brief`, which is author-facing content that belongs beside its page), so
they live together in `lazysite/auth/`, the same place as the other auth state.

## 2. Principles

Central store, not sidecars
: All ACLs live in `lazysite/auth/acls.json`, keyed by the content-relative path. No paired files in the content tree. The store sits in the already write-denied `lazysite/` subtree, so it is never writable by a raw WebDAV `PUT` - only through the ACL actions.

Opt-in, fail-open to scope
: No entry means no change - the account's `dav_scope` is the only confinement, exactly as before. An ACL only ever *narrows* access.

Owner is established by claiming, not impersonation
: Setting the first ACL for a file requires write access to it (per the existing scope). The owner is recorded as the claiming user - a normal user cannot name someone else. Thereafter only the owner (or an operator) may change or remove it.

Write protection is the headline; read is a bonus
: The primary use is "others cannot overwrite my pages". A `read` list additionally hides the *source* from other authors (the public still sees the rendered page - an ACL governs WebDAV/manager, not public serving).

Operators always win
: A manager-group operator bypasses ACLs in the manager - they administer the whole site. Over WebDAV there is no operator; enforcement is owner + lists only.

## 3. The store

```datatable
columns: Property | Value
widths: 4cm | X
bold: 1
tone: medium
---
Location | `lazysite/auth/acls.json` - one JSON object for the whole site.
Key | the content-relative path (e.g. `content/about.md`), the same key the dav and manager resolve.
Record | `{ "owner": "alice", "read": ["bob"], "write": ["alice","bob"] }`. `read`/`write` are optional allowlists of usernames.
Semantics | owner always allowed. A present list restricts that mode to owner + listed users; an absent/empty list leaves that mode unrestricted (scope applies).
Written by | the ACL actions only (`acl-set` / `acl-remove`); the store is inside the write-denied `lazysite/` tree, so no raw WebDAV write can touch it.
Read by | `lazysite-dav.pl` (enforcement) and the manager API.
```

## 4. Actions

Over the manager API (operator / owner) and the token control API (a partner
managing the content it owns, gated on the `webdav` capability):

```datatable
columns: Action | Effect
widths: 3.5cm | X
bold: 1
tone: medium
---
`acl-set` | Set `read`/`write` (and, for an operator, `owner`) for a path. Creating the first entry needs write access to the file and records the caller as owner; changing an existing one is owner-only (operators aside).
`acl-get` | Return the entry for a path (owner or operator only).
`acl-remove` | Delete the entry (owner or operator only) - the file reverts to scope-only access.
```

## 5. Enforcement

```datatable
columns: Surface | Read (GET / PROPFIND / open) | Write (PUT / DELETE / MOVE / save)
widths: 3.5cm | X | X
bold: 1
tone: medium
---
WebDAV | denied 403 if a `read` list excludes the user | denied 403 if a `write` list excludes the user
Manager | denied unless permitted or operator | denied unless permitted or operator
```

The manager Files page shows a file's `owner` where an entry exists. Not in v1
(deferred): `@group` entries; WebDAV ancestry-override (a manager-of-owner
overriding over dav); filtering individual children out of a PROPFIND listing
(a restricted file's *existence* is still visible; its content is protected); a
graphical permissions panel (set ACLs via the actions / raw JSON for now).

## 6. Build sequence

```datatable
columns: Step | Scope
widths: 3cm | X
bold: 1
tone: medium
---
1 | The central store + `load_acls` / `acl_allows` readers (dav + manager).
2 | WebDAV enforcement in `authorise` (read + write).
3 | Manager enforcement in read/save/delete with operator override; the `acl-set` / `acl-get` / `acl-remove` actions (manager + control API); Files-page owner display.
4 | Tests across both surfaces; spec + briefing docs.
```

## 7. Out of scope / deferred

- Group (`@group`) ACL entries - `[DEFER]`; usernames only in v1.
- WebDAV ancestry override - `[DEFER]`; the manager is the override surface.
- PROPFIND child-listing filtering - `[DEFER]`.
- A graphical permissions panel - `[DEFER]`; the `acl-*` actions for v1.
