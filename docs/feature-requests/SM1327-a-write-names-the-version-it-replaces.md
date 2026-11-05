---
id: SM1327
title: "SM1327: a write names the version it replaces"
subtitle: "MCP write_file saved without a modification time, so an agent writing back a file it had read replaced another writer's save. It takes an optional base_mtime: given and stale, nothing is written and the answer is a conflict naming the current mtime; absent, the write is what it was."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 51 (b) (tmp/rulings-2026-10-22.md, \"4 November\"), Q6, on T-06 of the inbox triage (tmp/inbox-triage-2026-11-04.md): a report from a site building a protected intranet, gap G1"
area: mcp
status-note: "SHIPPED (PENDING) on n744: write_file's base_mtime; rename_page's alias and link rewrite save with the time they read. t/unit/mcp/70."
---

# What was asked

Ruling 51 (2026-11-04): "replace_text saves with the mtime it read (0.16.3); write_file
gains an optional base_mtime and refuses on conflict (0.16.4) (T-06)." Part (a) is
SM1310. This is part (b), moved to 0.16.5 by ruling 63.

T-06 found every MCP write passing `undef` as the modification time to `action_save`,
which skips the conflict check when it is given none (`Manager/Files.pm`).

# What shipped

- **`write_file` takes `base_mtime`**, an integer: the `mtime` `read_file` answers
  (`read_page` answers the same time as `modified`). It is passed to `action_save`, so the
  manager's conflict check runs. The schema offers it, does not require it, and the tool's
  description says how to use it.
- **Given and stale**: nothing is written. The answer keeps `conflict: 1` and the current
  `mtime`, adds `kind: conflict`, and its sentence names that `mtime` and says to read the
  file again and make the change on what it holds now.
- **Given, for a file that no longer exists**: refused the same way, nothing created. The
  base names a version and a deleted file is not it; `action_save` alone would have
  created the file afresh. Writing without `base_mtime` creates it.
- **Given and not a whole positive number**: refused, `field: base_mtime`.
- **Absent**: unchanged. The file is written whatever it holds.
- **The two read-modify-writes inside other tools** save with the time they read, as
  `replace_text` does since SM1310: `rename_page`'s `add_alias` (the successor page's front
  matter) and `update_links` (each page that links to the old path). A page saved between
  the read and the write is left as the other writer saved it; the alias answers
  `alias_added: false` with the conflict as `alias_error`, and a rewritten page that
  conflicted is not counted in `links_updated`.
- The building-sites briefing (Publishing hygiene) says to write back with the version
  read.

# Tests

- **t/unit/mcp/70** (new): `read_file` and `read_page` answer the time; a matching base
  saves; a stale base is refused as a conflict naming the current `mtime`, the file is
  byte-for-byte unchanged, and a write with the named `mtime` then saves; a base for a
  missing file creates nothing; a base that is not a time is refused by name; no base
  writes as before (control); the schema offers `base_mtime` as optional. The alias and the
  link rewrite are given a second writer between their read and their save (a wrapper
  around `Files::action_save`, as t/unit/mcp/67 wraps `action_read`), and the other
  writer's change is kept.

With `lazysite-mcp.pl` put back to the base, 7 of the 9 subtests fail; the two controls
(the read answers, and no base) pass.

# Not done

- **The resolution is one second**, as SM1310 says: two saves in one second are not told
  apart.
- **The check and the write are not one step**: a save landing between them is still
  overwritten. The window is one `stat`.
- `copy_file` and `create_page` still pass `undef`: each refuses a target that exists, so
  there is no version for a base to name. `upload_file` writes bytes through
  `action_save_binary`, which has no conflict check; a base for it is not in the ruling.
