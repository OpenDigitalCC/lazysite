---
title: "SM232 - Subject-scoped export and erasure"
subtitle: "Gather everything associated with one identifier, hand it over as an archive, and remove it - the shape of an erasure request, which any site collecting form submissions can receive."
brand: plain
status: candidate
status-note: "Raised 2026-08-07. LOW PRIORITY and deliberately speculative: nobody has yet made an erasure request of a lazysite site. Filed now because the generic framing was reached while scoping a partner's bespoke want, and because both halves of the machinery already exist. Should not be built until something real pulls on it."
---

# SM232 - subject-scoped export and erasure

## Why

A partner asked for a way to hand a finished programme back: everything for one
participant gathered, delivered as a zip, and then removed from the site. Framed
that way it is bespoke - it needs participants, which lazysite does not have and
should not learn.

Framed generically it stops being bespoke. **Everything associated with one
identifier, exported and then removed** is the shape of an erasure request, and
any site that collects form submissions can receive one. It sits naturally with
the privacy commitments the platform already makes - no visitor tracking,
PII-free event logs, submission quarantine - and it is the one piece of that
posture with no mechanism behind it.

Today an operator facing such a request has the tools to do it wrongly: read the
submissions store by hand, edit a JSONL file, hope nothing else holds a copy.

## What exists already

Both halves are built, for other reasons.

- `Lazysite::Manager::Backups` creates tarballs of the docroot and streams them
  as a `Content-Disposition` attachment. Archive-and-download is solved; what it
  lacks is selection.
- The SM216 bulk delete rewrites a submissions store atomically through a
  temporary file and a rename, having validated every row id. Safe removal from
  an append-only store is solved; what it lacks is a subject.
- Submissions carry a stable `_id` per row, and forms are field-defined, so a
  field value is available as a selector.

The missing piece is small: select by subject across the places material can
sit, then reuse both.

## What to build

### Selection

Given an identifier - a value in a named field - find every submission row
carrying it, across every form store, plus any files uploaded with those
submissions.

### Export

Produce an archive of what was found, in a form a person can read without
lazysite: the rows as CSV or JSON, the uploaded files as themselves, and a
manifest saying what was gathered and when.

### Erasure

Remove exactly what was exported, through the existing atomic rewrite, and
**record that an erasure happened** - who requested it, which subject, how many
rows, when - without recording what was erased. An erasure that leaves no trace
is indistinguishable from data loss, and the trace must not reintroduce the data.

### Order

Export must succeed before erasure begins, and erasure must be a separate,
explicit action rather than a flag on the export. Handing someone their data and
destroying it in the same unreviewable step is how the wrong subject gets erased.

## The genuine conflict

Content history versions content and is designed to make change recoverable.
Erasure is designed to make content unrecoverable. If material subject to an
erasure request has ever been a page, those two guarantees are in direct
opposition, and no amount of care in this request resolves it.

The honest scope is therefore **submissions and their uploads**, where the
append-only store has no competing guarantee, with content pages explicitly
excluded and the reason stated. Extending to content would require deciding what
content history means in the presence of erasure, which is a larger question and
should be its own request if it ever arises.

## Open decisions

1. **What is a subject?** A field value on one named field is the simplest and
   covers the motivating case. Matching across several fields, or fuzzy matching,
   invites erasing the wrong person and should be resisted.
2. **Which capability?** It reads submissions and destroys them, so it is
   strictly more powerful than `read_submissions` and than the existing bulk
   delete. It probably wants its own grant, and it should be interactive and
   UI-only in the way `form-submission-delete` already is.
3. **Does export alone need the same grant?** Export without erasure is a read,
   and there is a reasonable case for it sitting under `read_submissions`.
4. **Retention of the archive.** If the export is written to the docroot before
   download, it is a second copy of exactly the material being erased. Streaming
   without ever landing it is the safer construction.

## Not in scope

- Content pages and content history, per the conflict above.
- Backups. A tarball taken before an erasure still contains the material, and
  reconciling that is an operator procedure rather than a feature. It should be
  documented alongside this, not solved by it.
- Any automatic or scheduled erasure. Every erasure is a deliberate act.

## Priority

Low, and deliberately so. This is filed because the generic framing is right and
the design is cheap to capture while it is fresh, not because anything is
waiting on it. Build it when a real request arrives, and revisit the open
decisions then - the answers may be obvious once there is a concrete demand
rather than an anticipated one.
