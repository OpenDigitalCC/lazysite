---
id: SM721
title: "SM721: uninstall keeps the data, and a fork can adopt it"
subtitle: "Phase 7 of the apps portability plan. The uninstall preview, reattachment on reinstall, and the one-shot operator-confirmed migration that lets a successor app take over a predecessor's retained tables."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 7 of 8.** Depends on SM716 (tombstones) and SM715 (ancestry). The
uninstall and reinstall halves are needed by the round trip (SM722); **fork
migration is not**, and can follow.

# What this phase delivers

## Uninstall

Previews like install: **pages that go, tables that stay, grants and bindings
released.** The register entry becomes the tombstone.

## Reinstall

Reattaches to the tombstone rather than colliding with it, and the retained
tables are adopted rather than recreated.

## Fork migration

A fork whose manifest declares ancestry to an uninstalled app with retained
data **may offer** migration: a one-shot, operator-confirmed copy of the
predecessor's tables into the fork's own namespace.

Three constraints, each load-bearing:

- **The source rows are left intact.** The data remains the instance's
  regardless of how the migration goes.
- Migration is offered **only when the tombstone confirms the predecessor was
  installed here**.
- **The declared ancestry must match.** An app declaring a predecessor it does
  not descend from fails validation.

# Why fork migration is here rather than later

Not because it is needed soon, but because it is the proof that the earlier
decisions were right. Ancestry recorded from the first manifest (SM715) and
provenance carried on the rows (SM717) exist precisely so this is possible
without a retrofit. Building it while those decisions are fresh tests them; if
it turns out to need something neither phase provided, that is worth knowing
before a population exists.

**Publish-as-fork** - take the current state, claim a new namespace, record
ancestry, leave the install running - is a later feature and not in scope here.
What this phase must not do is make it harder.

# Outcome test

- Uninstall previews the three lists, then does exactly that; tables remain.
- Reinstall reattaches to the tombstone and adopts the retained tables.
- A fork declaring ancestry to a tombstoned predecessor is offered migration;
  after it, both the source rows and the copies exist.
- A fork declaring an ancestry it does not have fails validation.
- Migration is not offered for a predecessor never installed on this instance.
