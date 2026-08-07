---
title: "SM232 - Subject-scoped export and erasure"
subtitle: "Gathering everything associated with one identifier and removing it is retention management for a document store, and lazysite is not one. Parked, with the reasoning recorded."
brand: plain
status: parked
status-note: "Raised and parked 2026-08-07. The operator's position: submissions are a capture surface, not a record store, and lazysite takes NO position on retention in either direction - any facility, including one built to dissuade, becomes retention workflow the moment it exists. Building erasure would legitimise using lazysite as a document store, which is not its purpose. Retained as a record because the analysis - particularly the history-versus-erasure conflict - remains true and should not be rediscovered."
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

PII does accumulate in JSON submission stores as a matter of course. That is a
consequence of collecting it, the client is the party who decided to collect it,
and the client is the party who carries the obligation that follows.

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

## No position on retention, in either direction

An earlier draft of this document proposed a narrower alternative: a retention
window after which submission rows age out. That is also wrong, and for a reason
worth stating because it is not obvious.

**Any retention facility becomes retention workflow.** A window that expires rows
is a retention policy engine. A scan that reports old material is a retention
report. Even a mechanism built explicitly to discourage accumulation teaches
operators that lazysite is the place where retention is decided, and from there
the requests are inevitable: exempt this form, extend that window, notify before
expiry, prove what was removed. The dissuading design and the enabling design
converge on the same product.

So lazysite offers nothing in either direction. It does not help material
persist, and it does not help material expire. Where records live, for how long,
and under what obligation are questions for whoever collected them, and there are
mature tools that exist to answer them.

This is not an evasion of the problem. It is a statement about which product
solves it.

## Not to be built

- Subject-scoped export.
- Subject-scoped erasure.
- Retention windows, expiry, ageing-out, or scheduled removal.
- Retention reporting, scanning, or any mechanism that surfaces how long material
  has been held - including one intended to discourage holding it.
- Any function whose effect is to make lazysite the place where retention is
  decided.
