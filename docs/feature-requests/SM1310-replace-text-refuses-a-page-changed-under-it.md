---
id: SM1310
title: "SM1310: replace_text refuses a page changed under it"
subtitle: "MCP replace_text saved without the modification time it read, so of two agents replacing text on one page at once, both answered replacements: 1 and one change was lost. It saves with that time now, and a page saved by another writer in between is refused as a conflict, nothing written."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 51 (a) (tmp/rulings-2026-10-22.md, \"4 November\"), Q6, on T-06 of the inbox triage (tmp/inbox-triage-2026-11-04.md): a report from a site building a protected intranet, gap G1"
area: mcp
status-note: "SHIPPED (0.16.3) on n739: replace_text passes action_read's mtime to action_save, and answers a conflict with kind conflict and a sentence telling the agent to run it again. t/unit/mcp/67. Part (b), write_file's base_mtime, is 0.16.4."
---

# What was asked

Ruling 51 (2026-11-04): "replace_text saves with the mtime it read (0.16.3); write_file
gains an optional base_mtime and refuses on conflict (0.16.4) (T-06)." This is part (a).

The report (gap G1): two agents ran `replace_text` on different lines of one page at
the same moment. Both answered `"replacements": 1`, and in 4 rounds of 5 one change was
missing. `replace_text` reads the file and saves it with `undef` as the modification
time (`lazysite-mcp.pl`), and `action_save` skips its conflict check when it is given
none (`Manager/Files.pm`), although `action_read` returns the time.

# What shipped

- `replace_text` passes the `mtime` its `action_read` returned to `action_save`, so the
  manager's existing conflict check runs: a page whose modification time is no longer
  the one read is not written.
- The conflict answer keeps `conflict: 1` and the current `mtime`, adds `kind:
  conflict`, and says the page was changed by another save, nothing was written, and to
  run `replace_text` again, which reads the file afresh.

# Tests

- **t/unit/mcp/67** (new): the second writer is put between replace_text's read and its
  save (the child loads the MCP script through a wrapper around `Files::action_read`),
  saving a line of its own a few seconds later by the clock. replace_text is refused as
  a conflict, the other writer's line is kept and this edit is not written over it; run
  again, both changes are there. One writer alone is the control.

With `lazysite-mcp.pl` put back to the base, the two-writer subtest fails all 8 of its
assertions.

# Not done

- **The check's resolution is one second.** It compares `stat` times, so a second save
  in the same second as the one before it is not seen. Two `replace_text` calls on a page
  written more than a second earlier are told apart; a burst within one second is not.
  `write_file`'s `base_mtime` (0.16.4, part (b)) meets the same limit.
- The check and the write are not one step, so a save that lands between them is still
  overwritten. The window is the length of one `stat`.
- The other MCP writes that pass `undef` (`copy_file` to a new path, the link rewrite,
  form and theme writes) are unchanged.
