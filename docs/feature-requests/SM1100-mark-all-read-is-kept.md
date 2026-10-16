---
id: SM1100
title: "SM1100: Mark all read is kept, or the bell says it was not"
subtitle: "The bell's read marks are written by renaming a new file over the old one, so a marker owned by another account is still replaced; a write that fails is an error the bell shows."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16
area: manager
status-note: "SHIPPED on n609: lib/Lazysite/Manager/Notices.pm, starter/lazysite/manager/layout.tt; t/unit/lib/202."
---

# What happened

The release manager on edge, 2026-10-16: marking all notifications read
"doesnt work". Asked which, the answer was that Mark all read fails: the bell
clears, and the notices are unread again on the next page.

`action_notices_seen` wrote the per-account marker,
`lazysite/logs/notices-seen.json`, with a bare `open '>'` and answered `ok`
whether or not the file opened. On a host where the engine's files are written
by more than one account, as on edge (the deploy report names files the
web-server user and `ispadmin` cannot both reach), the marker can belong to an
account the web server is not. The open failed silently, the page took `ok` at
its word and cleared the bell, and nothing was saved. Marking one notice read,
and Dismiss, wrote the same file the same way.

# What shipped

- The marker is written as a sibling file and renamed over the old one, in
  the group-writable `logs/` folder. That replaces a marker owned by another
  account, keeps its mode, and keeps every other account's position.
- A write that still fails answers an error (`kind: not-saved`) naming the
  file and `lazysite check --fix`, and is logged at ERROR. The manager bell
  shows it in the panel; the member's /account bell already showed an error
  it was given.

t/unit/lib/202: a marker the process cannot open for writing (mode 0444) is
still replaced and the mark kept; with `logs/` unwritable the answer is
`not-saved` and nothing is marked. On main, the first case answers ok and the
next read still finds every notice unread.
