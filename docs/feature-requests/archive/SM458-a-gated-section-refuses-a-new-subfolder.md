---
title: "SM458: the manager cannot create a subfolder inside a gated section"
subtitle: "\"Invalid path\" - for a path that was legal, in a section the account could write to, which WebDAV accepted seconds later. The message reads as you typed it wrong, so the operator tries other spellings of a name that was correct."
brand: plain
standard-margins: true
status: shipped
status-note: "FILED AND SHIPPED 2026-08-21 from the field, in 0.10.22 (05b0f3b, with 87837eb). BACKFILLED: this filing was written after the fix, when t/lint/26 - widened the same day to see qualified bullets - reported that 0.10.22 claimed an item with no feature-request doc. THE REPORT: an operator could not create `filestore/research` inside a gated `/intranet/`; the same folder went in over WebDAV immediately afterwards, so the path was legal and the account could write there. THE CAUSE: gating MOVES a section out of the document root into the private store (SM286), and validate_path resolves \"$DOCROOT/$rel\", falls back to dirname() for a path being created, and realpaths that - undef once the docroot parent is gone. THE FIX DELIBERATELY DID NOT WIDEN THE EXISTING CHECK: that containment test carries two CVE-class fixes and its own comment warns that widening it to span two trees is how a fix gets undone, so this adds a SECOND, separate check against the private root, each strict and boundary-safe in its own tree. IT COVERS FILES AS WELL AS FOLDERS, and the difference in how they failed is worth keeping: realpath tolerates ONE missing trailing component, so a file directly inside the gated root saved even before the fix, while a file one level deeper got past validation and failed at the write with 'Cannot write file: Permission denied ... run lazysite check --fix' - a worse message than 'Invalid path', because it names a cause that is not true and prescribes a repair that cannot help. Reproduced here, then confirmed by the operator's two-click test: ungated succeeds, gated fails."
---

# The message was the expensive part

```datatable
columns: Where | Said | Meant
widths: 4cm | 6cm | X
bold: 1
tone: medium
---
Folder, any depth | `Invalid path` | the path was legal
File, one level deeper | `Permission denied ... run lazysite check --fix` | permissions were fine; the repair could not help
File, directly inside | *(saved)* | `realpath` tolerates one missing component
```

*Invalid path* reads as **you typed it wrong**. An operator meeting it tries
other spellings of a name that was already correct, and the one thing they
will not try is the thing that would have worked.

The second message is worse than the first: it names a cause that is not true
and prescribes a repair that cannot help, so the operator's next step is a
tool run that changes nothing and confirms the wrong theory.

# Why the containment check was left alone

The existing test spans one tree and carries two CVE-class fixes, and the
code's own comment says that widening it to cover a second tree is how such a
fix gets undone. So the private root gets its own check rather than the
existing one getting looser -- two strict boundaries instead of one relaxed
one.
