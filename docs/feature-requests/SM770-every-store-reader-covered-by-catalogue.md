---
id: SM770
title: "SM770: every store reader is covered by catalogue, and no stat guard reads as absence"
subtitle: "Candidate, from the field's reply to SM768: a lint that names the stores it protects misses the store added in the same release. The stronger form covers every engine-owned store by catalogue, and treats a stat the process may not make as the fault an open it may not make already is."
brand: plain
standard-margins: true
status: candidate
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

# What would close it

- A catalogue of engine-owned stores (`lazysite/auth`, `lazysite/daemon`,
  `lazysite/connectors`, `lazysite/forms`, `lazysite/backups`, the private
  store ...) in one place, and lint 121 driven by it: every module that
  opens a path under a catalogued store is covered.
- The `-f`/`-e` guard rule applied across the catalogue, with the two
  cache-fronted readers restructured so the stat serves the cache key and
  never the absence decision.
- The answer, not only the log: a store reader's caller can tell "empty"
  from "cannot tell" - SM768's `undef` contract - wherever the answer is
  shown to an operator.
