---
title: "SM077 - File-manager UI overhaul: permissions, rename/move, locks, group ACLs"
subtitle: "Make the Files page manage ownership, moves, locks and group ACLs - in one pass"
brand: plain
---

::: widebox
The Files page already lists, edits, creates, deletes (single + bulk),
uploads/downloads, filters by type, and *displays* owner + `.brief`. SM077 fills
the four gaps that make it a complete manager: an **editable permissions panel**
(expand-in-place per row), **inline rename / move**, a **lock indicator**, and
**`@group` ACLs**. Scope + the permissions interaction were chosen 2026-06-24.
:::

## Status

**v1 built (`70f889d`/`e3cfded`, shipped in 0.4.1):** `@group` ACLs,
`Manager::Files::action_move`, `action_list` surfacing read/write + lock state,
and a first UI (expand-in-place row + appended badges).

**v2 built (2026-06-24):** a clean-row redesign after the v1 UI read as
cluttered (badges appended to the filename). The row is now icon + name on the
left; **Access** (owner + colour-coded `r`/`w`, `g` when a group is granted -
green = open, red = restricted), **Modified** (relative, absolute on hover,
linking to that file's audit history), a right-side select checkbox + select-all,
and a chevron that opens a per-file **config card** (one open at a time). The
card holds the permissions editor (Owner + Read/Write as native multi-selects
populated by a new `principals` action), Download, Add/Edit brief, Move, and
Save. Audit also gained an **origin** column (ui = cookie, api = control-API
token) and a **target filter** so the Modified link lands on one file's history.
Tests: `19-audit-target.t` (origin, target filter, back-compat, principals).
Full suite 1473.

**v3 built (2026-06-24):** the card's two native multi-selects are replaced by a
**unified rights editor** - one "People & groups with access" list where each
principal is a chip with `r`/`w` toggles + remove, added via a typeahead;
`read[]`/`write[]` are derived on save. The audit **History** link moved into
the card (off the Modified date) and the card is roomier. Also fixed a real
consistency bug: WebDAV had a private `acl_allows` that ignored `@group`, so a
group grant was dropped over WebDAV; it now delegates to the shared
`Auth::Acl` (groups resolved from `lazysite/auth/groups`), and `audit_log` is
shared so WebDAV + MCP writes are recorded too. Tests: `dav-publish.t`
(`@group` over WebDAV, dav audit), `19-audit-target.t`. Full suite 1479.

## 1. Permissions panel - expand-in-place

Clicking the owner chip on a file row expands the row to show inline read/write
editors (no modal):

```
[ ] about.md   owner: alice (v)        [edit] [del]
      Read  [ alice, bob          (+) ]
      Write [ alice               (+) ]   [Save]
```

- The chip shows the owner (or "unrestricted" when no ACL entry exists).
- Read/Write are token-style multi-selects over the **assignable principals** -
  managed users and groups (prefixed `@`); see group ACLs below.
- **Save** calls `acl-set`; clearing all fields + Save calls `acl-remove`.
- Operator sees/edits any row; an owner edits only their own (the API already
  enforces this - the UI just reflects it, hiding the control where `acl-get`
  returns "not the owner").
- Data: the listing already returns `owner`; extend `action_list` to also return
  the `read`/`write` lists (one `load_acls` per listing, already read for owner),
  so the expander needs no extra round-trip; `acl-get` stays the authoritative
  fetch for the operator view.

## 2. Inline rename / move

- New control on each row ("rename/move"); a small input for the new path.
- **New API action `move`** in `Manager::Files`: `move(old_rel, new_rel)` -
  validate both paths, deny-set both, refuse if the target exists, honour the
  per-file ACL (write on the source) and any live lock, move the file + its
  `.brief` sidecar + any generated `.html` cache, and carry the ACL entry across
  (re-key it in `acls.json`). Gated `webdav` like the other write actions.
- Directories move recursively (or refuse non-empty in v1 - decide at build).

## 3. Lock indicator

- `action_list` returns each file's lock state (reuse `_get_lock_info` /
  `_read_lock_record` + `_lock_fresh`): `{ locked_by, origin }` or none.
- The row shows a lock glyph with a tooltip ("locked by bob" / "locked via
  WebDAV"); editing/deleting a foreign-locked file warns first. No new API.

## 4. `@group` ACLs

- **Store**: `read`/`write` lists may contain `@groupname` entries alongside
  usernames (`Auth::Acl` already stores arbitrary strings).
- **Check**: extend `Auth::Acl::_acl_allows` so a `@group` entry matches when the
  requesting user is a member of that group. Group membership resolves from
  `lazysite/auth/groups` (cookie users) and the request's `X-Remote-Groups`
  where present; a token/WebDAV partner with no groups simply never matches a
  `@group` (safe default). The operator-bypass (`_is_operator`) is unchanged.
- **UI**: the Read/Write multi-selects offer groups (shown `@admins`) and users.

## Modules touched

- `Manager::Files` - the `move` action; `action_list` returns read/write +
  lock state; the move re-keys the ACL.
- `Auth::Acl` - `_acl_allows` matches `@group` via group membership (a small
  groups reader, or pass the user's groups in as context).
- `lazysite-manager-api.pl` - dispatch + `%need` for `move` (gated `webdav`),
  mirror the requester's groups into `Auth::Acl`.
- `starter/manager/files.md` + `assets/manager.css` - the expand-in-place
  permissions editor, the lock column, the rename/move control.
- Tests: extend `t/unit/lib/09-files-handlers.t` (move, ACL round-trip incl.
  groups) and `t/unit/lib/04-acl.t` (`@group` allow), plus a manager journey.

## Build order (suite-green per step)

1. `Auth::Acl` `@group` matching (+ the groups reader) - unit-tested in-process.
2. `Manager::Files::move` + the ACL re-key - unit-tested.
3. `action_list` returns read/write + lock state.
4. `files.md` UI: permissions expander, lock indicator, rename/move.
5. A manager journey test over the new flows.

## Risks

- **Group resolution for partners** - tokens carry no groups; `@group` simply
  never matches them (documented, safe). Confirm cookie users resolve groups
  consistently with how `_is_operator` reads `manager_groups`.
- **Move + locks/ACL** - re-keying the ACL and moving the `.brief`/cache must be
  atomic-ish; refuse on a live foreign lock, mirror `action_save`'s guard.
