---
title: "SM518: the rules move with the folder"
subtitle: "A directory move through the manager or MCP re-keyed only the exact source ACL key. Every rule on a path beneath it stayed at the old path - gated content silently public after a rename, with ok:1 and nothing reported."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-25 by the path-core structural review, proven by probe tmp/pathcore-probe.t P6: docs/team/a.md under read:[alice] became archive/team/a.md with no rule after action_move('docs','archive'). SHIPPED 0.10.32 (the beta build) on its own branch: action_move re-keys through Acl::rekey_path - the one definition, which DAV already used - and runs the SM286 private-store sync against every re-keyed key, parent before child. A folder that spans both trees (a public folder holding a gated file) is now renamed in each tree rather than having its store half dragged into the public destination; a mixed folder bound INSIDE a gated folder is refused rather than half-done. t/unit/manager/66-the-rule-goes-with-the-content.t 'a manager move of a folder carries every rule beneath it' pins the rule at the new key, gone from the old, a visitor read refused and the bytes in the store under the new key with no public copy. DAV's own move still carries only the store half through validate_path; PC-8 folds it onto this shape."
---

# The rule

*The rule follows the content, and the content follows the rule.* SM286
made the second half structural; CF-2 (SM430) made the first half true
on the DAV surface through `Acl::rekey_path`. The manager's move - the
surface the MCP `move_file` tool sits on - kept a hand-written re-key of
the exact source key, and a folder's descendants have no exact key.

# What happened

- `action_move('docs', 'archive')` returned `ok:1`.
- The store still held `docs/team/a.md` under `read: [alice]`.
- `archive/team/a.md` had no rule and no report, and the private-store
  sync - which runs only for a key that exists - never ran for it.

Through the manager the bytes of a per-file rule inside a public folder
were worse off still: the folder exists in both trees, `validate_path`
resolves it to the store half (private wins, the fail-safe direction for
a read), so the single rename carried the gated half into the public
destination and left the ordinary pages stranded at the old path.

# What changed

- The re-key lists every key at or beneath the source (the same prefix
  test as `rekey_path`, so `docs-archive` is not a child of `docs`),
  calls `rekey_path`, and syncs the private store against each new key
  in sorted order - a folder rule moves the folder, a file rule inside it
  then finds its bytes already placed.
- A folder present in both trees is renamed within each tree. No byte
  crosses trees in the rename step; the store sync is the one sanctioned
  mover. A mixed folder bound for a destination inside a gated folder
  would need the halves merged and is refused with a message that says
  what to do first.

# Left open

- `lazysite-dav.pl` `do_copy_move` re-keys correctly but still renames
  through `validate_path` alone, so a mixed folder moved over DAV carries
  its store half only. The review's PC-8 fold brings DAV onto the
  manager's helper; it should follow this change, not precede it.
