---
title: "SM508: a brief can be listed, and an orphan can be cleared"
subtitle: "The store had read, append and migrate - no list, no delete. An orphan could not even be discovered, and the agent that made one could not clean up after itself."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE SITE AGENT 2026-08-24 with three orphans on edge as the proof: brief-read needs a path you already know, so an entry whose page is gone was undiscoverable and unremovable by anyone but the operator at the filesystem. The agent named the pattern (same day, same shape as the drop safety-export gap): an agent authorised to do the thing is not authorised to clean up after it. SHIPPED 0.10.30: briefs-list / list_briefs (read, unaudited, manage_content) returns every store entry with path, size, mtime and an ORPHAN flag (no content answers its key); brief-delete / delete_brief (mutating, AUDITED - removing a record of intent is exactly what a trail should remember, manage_content) removes one by its listed path. The delete keys on the STORE, not validate_path - an orphan's content path may no longer validate (its directory can be gone), and refusing to delete precisely the entries that most need deleting would be the gap all over again. The operator's briefs-for-any-object proposal (filed the same day) names this as its PREREQUISITE: rows get deleted constantly, so widening the key space before the lifecycle existed would convert a small visible mess into an accumulating invisible one. t/integration/72 drives list-with-orphan-flag, clear, honest second-delete refusal and the explicit-path guard."
---

# The gap

The store shipped with `brief-read`, `brief-append` and `briefs-migrate`.
Nothing listed it; nothing deleted from it. `brief-read` needs a path you
already know, so an orphaned entry - its page deleted or renamed away
before SM507 - could not be discovered, let alone cleared. The site
agent's field test produced three such orphans and the pattern's name: an
agent authorised to do the thing is not authorised to clean up after it.

# The fix

Two actions, both `manage_content`, twinned across the API and MCP:

- **`briefs-list` / `list_briefs`** - every entry with `path`, `size`,
  `mtime` and an `orphan` flag (no content file answers its key). A read:
  skip-listed from the audit like every other read.
- **`brief-delete` / `delete_brief`** - removes one entry by its listed
  path. Mutating and **audited**: removing a record of intent is exactly
  what a trail should remember. The explicit-path guard is the acl-set /
  SM306 shape - the dispatcher's `/` default must never pick the entry.

The delete keys on the **store**, not on `validate_path`: an orphan's
content path may no longer validate (its directory can be gone), and
refusing to delete precisely the entries that most need deleting would be
the gap all over again.

# The prerequisite it satisfies

The operator's briefs-for-any-object proposal (typed keys; rows first)
names the lifecycle as its prerequisite: rows get deleted constantly, so
widening the key space before orphans were listable would accumulate an
invisible mess. This filing is that prerequisite, done first.
