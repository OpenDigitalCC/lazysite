---
title: "SM232 - Subject-scoped export and erasure"
subtitle: "Gathering everything associated with one identifier and removing it is retention management for a document store, and lazysite is not one. Parked, with the reasoning recorded."
brand: plain
status: parked
status-note: "Raised and parked 2026-08-07. The operator's position: submissions are a transient capture surface, not a record store; a client that needs material to persist should extract it and hold it where retention is properly managed. Building erasure would legitimise using lazysite as a document store, which is not its purpose. Retained as a record because the analysis - particularly the history-versus-erasure conflict - remains true and should not be rediscovered."
---

# SM232 - subject-scoped export and erasure

## Why this was raised

A partner asked for a way to hand a finished programme back: everything for one
participant gathered, delivered as an archive, and then removed from the site.

Framed generically that becomes **everything associated with one identifier,
exported and then removed** - the shape of an erasure request, which on the face
of it any site collecting form submissions could receive. Both halves of the
machinery already exist: `Lazysite::Manager::Backups` archives and streams, and
the SM216 bulk delete rewrites a submissions store atomically. The missing piece
looked small.

## Why it is parked

The generic framing is sound and the conclusion it leads to is wrong, because it
answers the wrong question.

**Submissions are a capture surface, not a store.** A form collects something and
hands it on. Material that matters should be extracted and held where it can be
managed properly - with a retention policy, a backup regime, an access model and
an owner. Lazysite provides none of those for submission data and should not
begin to, because providing them is what a document store does.

**Building erasure would legitimise the misuse.** A well-built export-and-erase
function is an invitation to leave material in the submissions store
indefinitely, on the basis that it can always be removed later. That is precisely
the pattern to discourage. The honest answer to "how do I erase a participant's
data" is that it should not have been accumulating there.

**Retention is the client's decision, and it should stay theirs.** Where material
persists, for how long, and under what obligation are questions about the
client's business rather than about publishing. A partner who owns that decision
can meet an obligation lazysite could only ever approximate.

The residual concern is real and is narrower than this request: PII does
accumulate in JSON submission stores as a matter of course. That is housekeeping,
and the answer is extraction and transience rather than an erasure function.

## The conflict worth keeping

Recorded because it is true regardless of what is built, and because it will
otherwise be rediscovered.

**Content history exists to make change recoverable. Erasure exists to make
content unrecoverable.** Those guarantees are directly opposed. Any future work
touching erasure of material that has ever been a page must decide what content
history means in the presence of an erasure request, and that decision is larger
than any convenience function that provokes it.

This is also why the append-only submissions store is the only place erasure
could ever have been straightforward - it carries no competing guarantee - and
why that convenience should not be mistaken for a reason to keep material there.

## If this is ever revisited

The narrower question that would deserve its own request is **transience**: a
retention window on a submissions store, after which rows age out
automatically. That manages a capture surface as a capture surface, keeps
material from accumulating in the first place, and needs no concept of a subject,
an export or an erasure.

It is not requested here. Filing it would need a real operator want rather than
an anticipated one.

## Not to be built

- Subject-scoped export.
- Subject-scoped erasure.
- Any function whose effect is to make lazysite a durable store for material the
  client should be holding elsewhere.
