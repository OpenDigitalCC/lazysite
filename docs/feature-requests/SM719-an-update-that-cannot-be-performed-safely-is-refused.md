---
id: SM719
title: "SM719: an update that cannot be performed safely is refused, and says what is blocked"
subtitle: "Phase 5 of the apps portability plan. Add-only is the default and the ceiling; anything beyond it without a declared migration leaves the app on its current version with the blocked operations named."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 5 of 8.** Depends on SM715, SM716 and SM717. Phase 6 extends this one.

# What this phase delivers

Two of the three update tiers. The third is SM720.

add-only
: The default. Insert reference rows whose stable key is absent; add a column
  with a default. **Nothing an author can get wrong, nothing that can
  destroy.**

declared but unperformable
: The update wants a removal, a type change, a rename, or anything else
  add-only will not do, and the author supplied no migration. **Refuse**: the
  app stays on its current version, and the apps list shows *update available*
  with **the specific blocked operations named**.

## The consequence that was accepted, and must be documented

An author **cannot correct shipped reference data**. A typo published is a typo
permanent, until a declared migration (SM720) exists to fix it.

This is a deliberate trade and it belongs in the authoring guide **in this
phase**, not in SM720. An author who learns it after publishing has learnt it
too late.

## Divergence is computed, never flagged

A modified package still takes updates: refresh the untouched files, preserve
the edited ones, **preview the plan first**.

Content history (git backend, tracks any file) provides the record, and ADR
0004's checksum-against-recorded plus the provenance stamp resolve each file
into app-unmodified, app-customised or operator-authored. The apps list shows
package state: **clean, or modified locally** - a derived state, never a flag.

Operators may modify anything. An installed app is the operator's to edit;
divergence is the raw material of future forks, not a fault.

# Why the refusal surface is in this phase

The refusal is the feature. A packaging system that silently declines to update
is indistinguishable from one that is broken, and an operator who cannot see
*why* an update is held has no route forward except to ask someone.

# Outcome test

- An add-only update inserts absent reference rows and touches nothing else.
- An update wanting a column removal, with no declared migration, refuses; the
  installed version is unchanged; the apps list names the blocked operation.
- An operator-edited file survives an update that refreshes its neighbours, and
  the preview said so beforehand.
- The apps list distinguishes clean from modified locally without any flag
  having been written at edit time.
