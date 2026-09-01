---
id: SM715
title: "SM715: an app declares what it owns and what it asks for"
subtitle: "Phase 1 of the apps portability plan. The manifest schema and its validation, including every declaration slot the later phases and the marketplace will need - present from the first version, unpopulated, because retrofitting a required declaration onto a live population is the failure the whole plan is arranged to avoid."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 1 of 8.** See `docs/plans/apps-portability-workplan.md` for the
sequence and what each phase unlocks. Nothing here depends on unbuilt work.
Every later phase depends on this one.

An app is a subfolder under the docroot containing pages, forms, client-side
JavaScript and typed data descriptors, together with the tables those
descriptors declare. **It has no server-side code of its own** and reaches the
server only through the existing gated surfaces - `lazysite-data.pl` for app
users, the control API for capability holders, the form handlers. That
containment is the foundation of the design and nothing in any phase weakens
it.

# What this phase delivers

The manifest schema and its validation, following ADR 0009's `owns` shape so
backup, site packages, the SBOM gate and the capability lints consume apps
through vocabulary they already read.

## owns

The subfolder, the table prefix and each table's descriptor, form
registrations, nav entries, cache participation, and dependencies - Perl
modules and required plugins **with their enabled state**.

## requests

Everything the app asks the instance for and an operator approves at install:

- roles, each with the capabilities its mapped group needs and a stated reason
- filesystem path prefixes outside its own subfolder, each with a reason
- egress connectors **by shape and purpose, never by URL or credential**
- declaration slots for triggers, timers and realtime channels

## ancestry

Empty for an original; the predecessor namespace and the version diverged from
for a fork. **Present from the first version because it cannot be retrofitted
onto a population.**

## The reserved seed columns

Descriptor validation enforces the two reserved column names every seeded row
carries: the seed key and the app version that introduced the row. The
behaviour that uses them is Phase 3; **the reservation is here**, because a
descriptor population written without them cannot be given them later.

# The slots that are inert on purpose

Triggers, timers, realtime channels and egress are **declared and validated
now, consumed by nothing**. They are waiting on SM221 and SM666 - the
persistent runtime, which introduces execution with no visitor present.

This is the single most important instruction in this phase and the easiest to
talk oneself out of, because a slot nothing reads looks like speculative work.
It is the opposite: the marketplace design record exists largely to establish
that these slots must be in the first manifest, so that the controls built
around them later are not retrofitted onto apps already in the field.

# Decisions already settled - do not reopen

These were taken with the operator on 2026-08-31.

Namespace is identity
: Claimed at creation, permanent, never re-available. A fork is a different app
  with a new namespace. **No relocation at install**: a conflict is a refusal,
  not a rename.

Roles, not groups
: An app never names a group. It declares roles in its own vocabulary.

No app pseudo-users
: Apps are not principals in the user or group stores. Audit entries name the
  human who acted; attribution to the app is by path.

# Open items - the operator decides

- Publisher-prefixed namespaces. Deferred, and it does not alter this design.

# Outcome test

- A manifest declaring every slot, including the inert ones, validates.
- A descriptor whose seeded table omits either reserved column is refused, by
  name.
- A manifest with no ancestry validates as an original; one naming a
  predecessor validates as a fork.
- **The exemplar check**: the messiest existing bespoke app can be fully
  described by this schema. Per ADR 0009's exemplar-first reasoning, a spec
  that survives the worst case absorbs the tidy ones - so this is done against
  that app on paper before the schema is called finished, not after.
