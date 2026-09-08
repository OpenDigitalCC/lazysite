---
id: SM770
title: "SM770: every store reader is covered by catalogue, and no stat guard reads as absence"
subtitle: "Candidate, from the field's reply to SM768: a lint that names the stores it protects misses the store added in the same release. The stronger form covers every engine-owned store by catalogue, and treats a stat the process may not make as the fault an open it may not make already is."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm770-every-store-reader-covered-by-catalogue. Lazysite::Stores catalogues every directory under lazysite/ as a store or not, with the reason written down; t/lint/121 is driven by it, so a directory the engine uses and the catalogue does not name FAILS - a store added next release is covered the day it appears. The lint also reads `or do { ... }` failure branches (the multi-line form SM768 itself introduced was invisible to the lint that asked for it) and refuses a -f/-e guard in front of a store read. Eight guards removed (Auth::Acl, Auth::Session x4, Auth::Settings x3) and the daemon's readability pre-flight now asks by opening; read_settings routes through cannot_read and its stat serves the cache key only. t/unit/auth/22 proves the case the guards hid: an auth DIRECTORY without its search bit, where every reader answered empty and none of them logged."
---

# What the field asked

SM766's lint (`t/lint/121`) holds that no reader of a store under
`lazysite/auth/` or `lazysite/daemon/` returns empty in silence. The
connector store, added in 0.13.5, was not on its list, and the field found
it the same way SM760 was found. SM768 added `Manager/Connectors.pm` to the
list; the field's stronger form is a lint that requires **every**
engine-owned store directory to have a conforming reader, so a store added
later is covered by default instead of being remembered.

# The second half, found on the way

A `-f` guard in front of a store open renders a directory the process may
not search as an absent store before the open - and the logger - is
reached. SM768 removed the guard from the connector store and refuses one
there by lint. The auth store still carries eight (`Auth/Settings.pm`,
`Auth/Acl.pm`, `Auth/Session.pm`); each guarded open there does reach
`cannot_read`, so a permissions fault on the file is logged, but the
directory case is not. Two of them sit in front of an mtime cache, so the
removal is not mechanical.

# What was built

- **`Lazysite::Stores`** - every directory under `lazysite/` classified as a
  store or not, each non-store carrying the argument for why the rule does
  not apply (a cache entry that will not open IS an empty one; rendered
  output is rebuilt; an archive fails its restore loudly). Three stores:
  `auth`, `daemon`, `connectors`.
- **`t/lint/121` driven by the catalogue**, and stronger in two more ways:
  a directory the engine uses that the catalogue does not name is a failure
  (so a store added next release is covered the day it appears), and
  `or do { ... }` counts as a failure branch - the multi-line form SM768
  itself introduced was invisible to the lint that asked for it.
- **The eight stat guards removed** (`Auth::Acl`, `Auth::Session` x4,
  `Auth::Settings` x3), and the daemon's readability pre-flight asks by
  opening rather than by `-e`. `read_settings` routes through `cannot_read`
  and its `stat` serves the cache key only.
- **`t/unit/auth/22`** proves the case the guards hid, which is not an
  unreadable file but an unreadable DIRECTORY: with the search bit off
  `lazysite/auth`, every `-f` inside answers false whatever the files say,
  so the account store read as "no accounts" and a capability lookup as
  "holds nothing" - silently. Every reader now logs the file, the error and
  the unix user; an absent store still says nothing.

# Not built, and why

**The `undef` contract for the auth readers.** SM768 gave the connector
store three answers (set / not set / cannot tell) because `has_secret` is
shown to an operator. The auth readers feed GATES, where an empty answer
means "grants nothing" - which is the safe direction to fail in, and
changing `caps_for` to return undef would push that decision into every
caller. So the auth stores keep their empty answers and now always say so
in the log. Where an auth answer reaches an operator rather than a gate,
that is the place to revisit this.
