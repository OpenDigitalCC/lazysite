---
id: SM981
title: "SM981: A move into a held-back folder left the file public"
subtitle: "A file carrying a rule of its own, moved or copied into a draft or read-gated folder, was moved back out of the private store into the document root; a draft folder then served it to anyone. Every write now lands where save would, and acl reapply repairs a folder held in both trees."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox, 2026-10-11-a-move-into-a-draft-folder-leaves-the-file-public.md (a local site at 0.15.3, the 0.15.4 tree)
area: security
status-note: "SHIPPED (0.15.5): ruled 2026-10-11, Land where save would. Placement is decided by every rule that governs a path (Acl::placement_for), on the manager's and WebDAV's store sync and in resolve_for_write; the processor's draft check asks only entries carrying draft; move_in merges a path held in both trees (private kept, public moved to lazysite/displaced/). t/integration/126."
---

# What was wrong

Reported: a folder held back with `lazysite-acl.pl set /drafts --read
@authors,@sysops --write @authors,@sysops --draft`; an editor took a post down
with `move?path=/post/NAME.md&to=/drafts/USER--NAME.md`. The move answered ok,
the bytes landed in the PUBLIC docroot, and an anonymous request answered 200
with the post. A `save` to the same folder went to the private store. `acl
reapply --apply` refused to repair it: "the private store already holds this
path".

## Root cause (measured, not assumed)

A file moved into the folder WITHOUT a rule of its own lands privately on main:
`validate_path` resolves the target through `Private::resolve_for_write`, whose
tree walk finds the folder in the store. The leak needs the file to carry a
rule of its own - an owner-only rule, which every manager copy writes
(`action_copy`), a CLI `--owner` writes, and a move re-keys:

1. **The movers judged placement by the moved path's own rule.**
   `action_move` (`lib/Lazysite/Manager/Files.pm`) re-keys the moved path's rule
   and calls `_sync_private_store($new, $acls->{$new})`, which decided
   `move_in` or `move_out` from `_acl_gates_public($rec)` - the record's own read
   list or draft. An owner-only rule "does not gate", so the file was moved OUT of
   the store into `public_html/drafts/`, recreating the folder in the docroot.
   WebDAV MOVE (`lazysite-dav.pl` `_sync_acl_store`) did the same. `acl-set` of a
   write-only rule, or `acl-remove` of a file's own rule, inside a held-back
   folder did the same.
2. **A public folder then captured every later write.** `resolve_for_write`
   settles a new path by its nearest existing ancestor, docroot first; once the
   stray `drafts/` existed, saves, uploads and PUTs into it all went public.
3. **The draft flag was hidden.** The processor's `_acl_is_draft`
   (`lazysite-processor/acl.pm`) took the nearest entry of ANY kind, so the
   file's owner-only entry beat the folder's `draft: true`; in a draft folder with
   no read list the page was served to anyone - the reported 200.
4. **The repair refused.** `Private::move_in` refused a path the store already
   held, so re-issuing the folder's rule (`acl reapply`) could not bring the
   stray in.

Reproduced on main (41967751), `tmp/sec-evidence/sm981-probe3.pl`
(`.main.out`): a move of an owned post into `drafts` (read list + draft) and
into `members` (read list) lands PUBLIC; the next save into `drafts` lands
PUBLIC; a move of an owned post into a draft-only folder lands PUBLIC and the
anonymous request answers 200 with its text. t/integration/126 run against main
fails 30 assertions (`sm981-t126.main.out`).

# The ruling

Release manager, 2026-10-11, "Land where save would":

move, copy, file-upload, and MCP move_file/copy_file/upload_file and WebDAV
MOVE/COPY/PUT into a path governed by a rule that relocates content (draft or a
read list) land the bytes where save would (the private store). Same for
read-list folders. Also fix `acl reapply`, which refuses when the private store
already holds the path, so a misplaced file can be repaired (decide the safe
answer when both copies exist: never expose - say which store wins and why, and
keep the other as a recoverable backup rather than deleting it).

# The fix

- **One answer to "where do these bytes belong".** `Lazysite::Auth::Acl::
  placement_for($docroot, $rel)` answers `private` when ANY rule governing the
  path relocates content - its own, its page stem's, or an ancestor folder's read
  list or draft (`relocating_key`); `public` when none does; `unknown` when the
  store cannot be read. The site-wide rule never relocates.
- **The movers ask it.** `Files::_sync_private_store` (manager move, acl-set,
  acl-remove, MCP move_file and set_permissions through them) and WebDAV's
  `_sync_acl_store` move a path into the store when its own rule OR
  `placement_for` says so; `unknown` moves nothing out.
- **Writes ask it.** `Private::resolve_for_write` sends a NEW path a relocating
  rule governs to the private store whatever the trees say, so save, upload,
  copy, MCP write/copy/upload_file and WebDAV PUT/COPY land there even with a
  stray public folder in the way. The tree walk still decides what the rules
  leave open, and `unknown` leaves it to the tree as before.
- **The draft check asks only entries carrying `draft`** (the SM268 H10
  reasoning applied to the flag): an owner-only rule no longer hides its folder's
  draft flag.
- **The repair merges.** `Private::move_in` of a path both trees hold no longer
  refuses (`_merge_in`): a folder merges file by file; what the store lacks moves
  in; for a file both hold, **the private store's copy wins** - it is the copy the
  rule governs and the engine has been serving under it (`resolve` prefers it) -
  and the public copy is moved to `<engine tree>/displaced/<UTC stamp>/<path>`,
  outside the document root and the store (the engine tree the front door refuses
  and the shipped front-end configs deny), where a sysop can recover it. Nothing
  is deleted; every displaced copy is named in the reply (`acl reapply` prints
  it). A symlink is displaced, never moved into the store. A file against a
  folder is refused, moving nothing.

# Behaviour changes

- A file moved, copied or uploaded into a draft or read-gated folder lands in the
  private store even when it carries a rule of its own, and changing or removing
  its own rule there leaves it in the store.
- A file in a draft folder is a draft (404 to the public, unlisted) whatever
  rule of its own it carries.
- `acl reapply --apply` (and any re-issue of a rule) merges a folder found in both
  trees instead of refusing; the public copy of a file both trees hold is moved to
  `lazysite/displaced/`.

# Evidence

t/integration/126 (manager save/move/copy/upload, MCP move_file/copy_file/
upload_file, WebDAV MOVE/COPY/PUT, the processor's draft check, own-rule
changes, the stray folder and the reapply repair; 30 assertions fail on main),
t/unit/lib/20-private-store (the refusal it asserted is now the merge, and a
file against a folder is refused both ways). Sabotage: 12 cases
(`sm981-sab*.out`), each bit; the file-against-folder guard first did not, and
the test gained the direction where it matters.
