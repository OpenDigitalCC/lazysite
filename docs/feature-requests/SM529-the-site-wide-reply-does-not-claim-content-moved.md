---
title: "SM529: the site-wide reply claims content moved when nothing did"
subtitle: "A root ACL or a write-only rule returns content_moved with the moved note while its own warning says it moves no files."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the path-core structural review, PROVEN by probe tmp/pathcore-probe.t (P3, evidence in tmp/pathcore-probe.out); class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. action_acl_set('/') returns content_moved => 1 and the content-moved-out-of-the-document-root note while its own warning says a site-wide rule moves no files: the root branch at Manager/Files.pm 1400-1408 returns before the mover runs and the flag keeps its local value of 1. A write-only rule returns reads_unrestricted => 1 and content_moved => 1 with the same note, so the SM479 field is contradicted by the sentence beside it. Fix: the helper clears the flag on the root branch and when no rule gates reads, and the note is worded by direction."
---

# The finding

`action_acl_set('/')` returns `content_moved => 1` and `content_moved_note
=> 'content moved out of the document root...'` while its own warning
says a site-wide rule moves no files. The root branch (`Manager/Files.pm
1400-1408`) returns before the mover runs, and `$CONTENT_MOVED`
keeps its `local` value of 1. A write-only rule (no read list) returns
`reads_unrestricted => 1` and `content_moved => 1` with the same note -
the SM479 field is contradicted by the sentence beside it.

# Why it matters

Correctness: `content_moved` is the structural signal an agent reads to
know whether files changed location. A flag that is set when nothing moved
teaches callers to distrust it, and the note beside it tells an operator
something that is untrue.

# The proving test

Add to `t/unit/manager/67-root-acl-writer.t` the assertion "the site-wide
reply does not claim content moved". `t/unit/manager/73` keeps its
positive assertion.

# Fix shape

The helper sets `$CONTENT_MOVED = 0` on the root branch and when `!$gates`
(or reports a direction), and the note is worded by direction.
