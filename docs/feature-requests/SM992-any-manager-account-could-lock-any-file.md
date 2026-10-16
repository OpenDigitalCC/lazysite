---
id: SM992
title: "SM992: any manager account could lock any file"
subtitle: "lock, renew-lock and unlock asked no file rule, so an account that could not write a file could hold it against its writers, and release anybody's lock. A lock is now a writer's, on the manager and over WebDAV."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM979's inventory, left there for a ruling (`lock` asks no file rule)
area: security
status-note: "SHIPPED (0.15.5): ruled 2026-10-12, Lock needs write access. The manager's lock, renew-lock and unlock refuse a caller the path's write rule refuses (Files::lock_refusal); WebDAV's UNLOCK is authorised as a write, as LOCK was; the operator's force-unlock is unchanged. t/integration/129."
---

# What was wrong

SM979's inventory found that the manager's `lock` asked no file rule. The
dispatcher (`lazysite-manager-api.pl`) called `acquire_lock`, `release_lock` and
`renew_lock` (`lib/Lazysite/Manager/Files.pm`) with the path and the account and
nothing else, and the actions carry no capability gate. So any manager account
- one whose rules let it write nothing - could lock any file, and every writer's
`save` was refused "File is locked by ..." until the lock expired (and renewing
it kept it); and `unlock` removed any manager lock, whoever held it.

WebDAV already authorised `LOCK` as a write (`lazysite-dav.pl`, `$is_write`), so
a non-writer could not take a WebDAV lock. `UNLOCK` was not a write: only the
lock's own holder may release it (token and user checked in `do_unlock`), but a
holder whose write the rule had since taken away still released it.

Measured on n384: 15 assertions of t/integration/129 fail
(`tmp/sec-evidence/sm992-t129.base.out`).

# The ruling

Release manager, 2026-10-12, Finding 2, "Lock needs write access": lock /
renew-lock / unlock (API, and any MCP/WebDAV equivalent - WebDAV LOCK?) require
the caller to be able to write that file under its rule; everyone else refused;
the operator's force-unlock unchanged. Test + sabotage.

# The fix

- `Files::lock_refusal($path, $account)`: `validate_path`'s own refusal for a
  path it rejects, else `_acl_denied($rel, 'write', $account)` - the per-file
  check every manager write asks. The dispatcher asks it before each of `lock`,
  `unlock` and `renew-lock`; a refusal is 403 `kind: permission`, and no lock is
  written or removed. It is not inside `acquire_lock`, which the theme and
  layout activations also call for their artefact locks on paths no file rule
  governs.
- WebDAV: `UNLOCK` joins `LOCK` in the write methods, so `authorise` asks the
  path's write rule (and the capability, scope and blocklist a write asks).
- The operator (a member of the operator group, SM991), `local` and an
  unsecured site pass `_acl_denied` as they pass every file rule, so the
  operator's release of somebody else's lock - the "Take over" a stale lock
  offers - is unchanged. A writer may still release another writer's manager
  lock, as before.
- MCP has no lock tool, and the control API serves `lock`, `unlock` and
  `renew-lock` only to the manager's cookie session; nothing else takes one.
- The editor, refused a lock, says why and disables Save instead of showing the
  file as being edited.

# Behaviour changes

- A manager account the path's write rule refuses is refused `lock`,
  `renew-lock` and `unlock` (403) on that path. A path no rule governs locks as
  before.
- A WebDAV `UNLOCK` by a caller the path's write rule refuses is 403 and the
  lock stays (until it expires, or a writer or the operator releases it).

# Evidence

t/integration/129 (manager and WebDAV; 15 assertions fail on n384, all pass
after). Sabotage: 6 cases (`tmp/sec-evidence/sm992-sab*.out`) - each of the
three dispatch checks removed, the refusal emptied, the rule asked for `read`
instead of `write`, `UNLOCK` dropped from the write methods - each bit.
