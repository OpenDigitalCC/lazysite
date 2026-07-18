---
title: "SM175 - Content history that follows renames"
subtitle: "A move carries a file's history; a delete ends its thread; a new file at a used name starts clean"
brand: plain
status: candidate
status-note: "raised 2026-07-18; targeted at 0.7.26. Builds on SM162 (folder/file move dropdown) and the existing move / rename_page / WebDAV MOVE ops."
---

# SM175 - Content history that follows renames

## Why

Field observation: moving a file loses its content history, and *how* the agent
performed the move changes the outcome. Two things are wrong, in opposite
directions, and both come from one place - `Lazysite::Git::file_log` runs
`git log -- <path>` with **no `--follow`**:

- **A move loses its history in the view.** Renaming `a/page.md` to `b/page.md`
  leaves the old history under the *old* path; the new path's timeline starts at
  the move commit. The history is not destroyed - the *view* cannot see across
  the rename.
- **A recreate leaks history.** Because the log is keyed on the pathname, if
  `secret.md` is deleted and a brand-new, unrelated `secret.md` is later created,
  `git-history secret.md` shows the **old** file's entire timeline. This is the
  leak-into-the-future the operator flagged, and it is live today.

Compounding it, the per-file history exists only as an API (`git-history` /
`git-show` / `git-restore`) with no surface in the Files page, so the file itself
is effectively the only thing an operator can review - which is why a broken link
feels like the history is dead.

The desired contract is simple and the operator stated it exactly: a move retains
history; a delete ends the thread; a new file at a used name does not inherit the
past; only a literal operator delete-then-recreate is an intentional, untraceable
reset.

## What happens today

The plumbing is better than the symptom suggests; the *view* is the fault.

- **Move ops already exist and commit atomically.** Control-API `move`
  (`action_move`), MCP `rename_page` (which calls `action_move`), and WebDAV
  `MOVE` (`do_copy_move`, committed as *one* commit, SM085) all do a real
  server-side rename. A single-commit delete+add of identical content is exactly
  what git needs to recognise a rename.
- **`file_log` throws that away.** It lists `git log -- <rel>` without `--follow`,
  so the new path shows nothing before the move, and a reused path shows every
  commit that ever touched that name.
- **History is not reviewable in the UI.** `git-history` / `git-show` /
  `git-restore` are wired on the control-API and MCP but have no Files-page
  affordance.

Net: genuine moves *lose* history, and delete+recreate *inherits* it - both
backwards from the contract.

## Target semantics

move / rename
: history follows the content to its new path.

delete
: ends the thread. Nothing committed afterwards can inherit it.

create at a previously-used path (no rename link)
: a new thread; no inheritance of the prior file's history.

operator delete-then-recreate (bypassing the move op)
: an intentional, untraceable reset - accepted, and the only way to sever
  lineage on purpose.

## Design

**Empirical finding (git 2.47.3), which settled the approach:** `git log
--follow` follows a rename backward, so it fixes the "moved file lost its
history" half - but it does **not** stop the delete/recreate leak. Both
`git log -- path` and `git log --follow -- path` still list *every* commit that
ever touched the pathname, so a fresh file at a previously-deleted path still
shows the deleted file's timeline. `--follow` is therefore insufficient on its
own; the explicit-lineage mechanism below is the core, not an optional hardening.
(The original two-tier framing collapsed into one.)

### The mechanism - explicit lineage (deterministic)

- Every move commit carries a machine-readable trailer
  `Lazysite-Renamed-From: <old rel path>` (the terse subject stays
  `move a/x.md -> b/x.md`).
- `file_log` walks lineage by **explicit link only**: the history of path `P` is
  the commits since `P`'s current creation, plus - if that creating commit carries
  the trailer - the lineage of the named source, recursively. The walk never
  crosses a plain delete-then-add at the same path.
- This makes the contract independent of content similarity: a delete writes no
  rename link, so a later create at the same path (identical content or not)
  cannot inherit the deleted thread.

### Moves first-class and reliable

- One internal `Lazysite::Git::move($docroot, $user, $from, $to)` performs the
  atomic rename, commits it, and writes the trailer. `action_move` and WebDAV
  `MOVE` funnel through it, so every channel produces the same detectable,
  linked, single-commit rename.
- Verify `action_move` commits as one rename commit (WebDAV already does).

### Agent steering (as SM161 did for forms)

The move ops exist; the risk is an agent hand-rolling a move as
`write_file(new)` + `delete_file(old)` - two commits, possibly edited content, no
link - which defeats history however clever the log walk is.

- Update the `create_page` / `write_file` / `delete_file` tool descriptions and
  the MCP `initialize` instructions: *"To rename or move a page use `rename_page`
  (or `move`); never write a new file and delete the old one - that breaks the
  page's history."*
- Advisory audit signal: a delete immediately followed by a same-content create
  at another path within a session is flagged *"looks like a hand-rolled move -
  use `rename_page` so history follows"*.

### Surface history in the Files UI

- Add a per-file **History** affordance on the Files page backed by the existing
  actions: list versions (id, author, date, message), view a version, diff
  against current, restore. It pairs naturally with the SM162 move dropdown.
- Without a review surface, preserved history is invisible; this is the operator's
  "no way to review except the file itself".

## The leak guarantee

History is **never leakable into the future across a delete/recreate boundary.**
Only a rename link carries a thread forward, and a delete writes no rename link.
A recreate at a used name therefore always starts clean. This holds by
construction for every case (including an identical-content recreate), because
the walk follows the explicit trailer, never git's content-similarity guess.

## Storage and compatibility

- Nothing new is stored in content - only commit trailers, which live in the git
  log and never appear in a file.
- The lineage walk applies to moves made after the upgrade (they carry the
  trailer). A move made by an older version has no trailer, so its history simply
  starts at the move commit - the pre-SM175 behaviour, and never a leak. No
  migration.
- `git-history` output shape is unchanged (a list of versions); it simply returns
  the correct set.

## Edge cases

Copy / duplicate
: not a rename. A copy is a fresh file with its own new thread; the source keeps
  its history. No trailer is written for a COPY.

Move onto an existing path (overwrite)
: the overwritten file's thread ends (it was replaced); the moved file's lineage
  continues. Precedence defined and tested.

Move across a scope boundary
: still subject to confinement - a move cannot smuggle a file out of a user's
  content-root scope. The destination is authorised exactly as WebDAV
  `do_copy_move` already authorises the Destination header.

Directory move
: a folder rename is many file renames in one commit (SM085 batches MOVE); each
  file carries its lineage, so the whole subtree's history follows.

Limit / performance
: `--follow` and the lineage walk are bounded by the existing history limit
  (<= 200 entries).

## Tests

- **Leak regression (security-relevant):** create, edit and delete `x.md`; later
  create a new `x.md`; assert its history contains only its own commits, never
  the deleted file's.
- **Move follows:** rename `a/x.md` to `b/x.md`; assert `b/x.md`'s history
  includes the pre-move edits.
- **Deterministic lineage:** a move writes `Lazysite-Renamed-From`; the walk
  follows it; a delete-then-recreate with *identical* content does **not** inherit
  (beats the similarity heuristic).
- **Move op / channels:** `action_move` and WebDAV `MOVE` each produce a single
  rename commit with the trailer; destination scope confinement still enforced.
- **Agent steering:** the create/write/delete tool descriptions and `initialize`
  carry the "never hand-roll a move" guidance (a docs-consistency test, like the
  forms one).
- **UI:** the Files history panel lists, shows and restores via `git-history` /
  `git-show` / `git-restore`.

## Out of scope

- **Cross-site history transfer** (moving content between two content roots /
  domains) - that is a copy into a different history and a fresh thread.
- **Blob-level or content-addressed lineage** - path plus explicit trailer is
  sufficient.
- **Undo of a delete** beyond `git-restore` of a known prior version.

## Rollout

Landed as one mechanism for 0.7.26 (branch claude/rename-history): the
`Lazysite-Renamed-From` trailer + lineage walk in `Lazysite::Git`, the move ops
routed through it (manager Move, MCP rename_page, WebDAV MOVE), the agent
steering, and the Files history panel following renames (including view / diff /
restore of pre-rename versions via a server-resolved historic path).
