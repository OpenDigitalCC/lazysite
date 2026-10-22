---
id: SM1262
title: "SM1262: a bundle is adopted once, and a deleted one stays deleted"
subtitle: "Bundle adoption could not tell a bundle a site never had from one an operator deleted, so a deleted bundle came back on the next use of the users tool. The bundles a site has had are now recorded, and a recorded bundle is never adopted again."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, ruling on SM1241's open question (2026-10-22)"
area: users
status-note: "SHIPPED (PENDING) on n725: auth/bundles-adopted.json records every shipped bundle a site has had, written on a fresh seed, at the first run on an upgraded site, and on each adoption; _adopt_added_bundles skips a recorded bundle and adopts nothing when the record cannot be read. t/unit/users/56."
---

# What happened

[[SM1241]] adopts every shipped bundle that is absent from a site. Absent is all the
group store says, so a bundle an operator deleted looked like one the site never had. The
next use of the users tool brought it back, with its shipped roles nested in it. A
deleted `ch-files` gave WebDAV back to content-editors, design-team and site-admins.
[[SM1118]] had the same exposure for cap-maintenance.

The ruling (2026-10-22): adoption records what it adopted, once, and never re-adopts a
bundle an operator later deleted. Sites that already had a bundle adopted must count as
adopted.

# Where the record lives

`lazysite/auth/bundles-adopted.json`, beside `groups-settings.json`:
`{ "bundles": [ ... ] }`. It is written 0660 by `Util::write_private_atomic`, like the
other auth stores.

The ruling suggested a marker in `groups-settings.json`. That file is read by more than
fifty callers in the engine, the processor and the manager, and each of them takes every
top-level key for a group. A marker key would appear as a group on the Groups page and in
every group walk. A marker on a bundle's own record is no help, because deleting the
bundle removes the record. So the record has its own file in the same directory, and it
travels with the auth store.

# What shipped

- **What counts as had:**
  - every shipped bundle present when `_adopt_added_bundles` runs, so a bundle SM1118 or
    SM1241 adopted, or the seed gave, counts on the first run after an upgrade;
  - every bundle adopted in that run;
  - on a fresh site, every bundle the seed wrote.
- **A recorded bundle is never adopted again.** The record is written only after the
  group store and the nesting are written, so a failed write never marks a bundle the
  site did not get.
- **A record that exists and cannot be read adopts nothing** and is not written over.
  It cannot say what the site had, and guessing would bring back what an operator
  deleted.
- An absent record is read as empty: that is a site from a release that kept none.
  `ops.work_users_tool_statements` is now 3874 (lint 216).

# Tests

t/unit/users/56, new block:

- ch-files is adopted and recorded, in a 0660 file;
- an operator deletes it (through the users tool's `group-delete`), and two more uses of
  the tool do not bring it or its nesting back;
- on a site with no record, the first run records cap-maintenance, and once deleted it
  stays deleted;
- an unreadable record adopts nothing and is left as it is.

With the change reverted, seven assertions fail, including "THE NEXT USES OF THE TOOL DO
NOT BRING IT BACK". SM1241's own blocks and t/integration/321 now remove the record as
well as the bundle when they reshape a store as an earlier release left it, because an
earlier release kept no record.

# Not done

- `reset-groups` and the single-group restore (SM644, SM667) still restore a seeded
  bundle on an operator's explicit request. That is a deliberate restore, not adoption.
