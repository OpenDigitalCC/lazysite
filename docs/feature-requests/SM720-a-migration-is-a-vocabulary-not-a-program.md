---
id: SM720
title: "SM720: a migration is a vocabulary, not a program"
subtitle: "Phase 6 of the apps portability plan. A fixed, inspectable set of declarative operations, previewable and backed up before it runs - and an explicit ceiling, because arbitrary transformation code is not something a package carries."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 6 of 8.** Extends SM719. Not required for the round trip (SM722), so it
can land after critical mass if the schedule wants it to.

# What this phase delivers

The third update tier: an author-supplied **declarative** migration drawn from
a fixed vocabulary - rename column, backfill from another column, split a table
- inspectable and previewable.

## The vocabulary is the ceiling

**Arbitrary transformation code is not carried by a package.** Anything beyond
the vocabulary is a manual operator job, and that is the answer rather than a
gap to close later.

This is the decision most likely to be argued with during implementation, by
whoever meets the first migration the vocabulary cannot express. The correct
response is to add a *considered* operation to the vocabulary or to refuse -
never to admit an escape hatch that executes author-supplied code, because an
app has no server-side code of its own and this would be the one place it did.

## Before it runs

**An automatic backup of the affected tables precedes any non-add-only
migration.** Backup participation already exists through `owns.storage`, so
this is wiring rather than new machinery.

## Smallest useful set first

Build the vocabulary from operations actually wanted by the exemplar apps, not
from a survey of what migration systems usually offer.

# Outcome test

- Each operation in the vocabulary previews accurately, then performs what the
  preview said.
- A migration declaring an operation outside the vocabulary is refused at
  validation, before install offers it.
- The affected tables are backed up before any migration runs, and the backup is
  restorable.
- A migration that fails part-way leaves the app on its previous version, with
  the backup named in the refusal.
