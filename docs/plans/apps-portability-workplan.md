---
title: "Apps portability and the marketplace: workplan"
subtitle: "SM715-SM723, sequenced. Eight core phases chipped away alongside ordinary releases until the round trip passes, which is critical mass; the marketplace becomes buildable only after that. Derived from the two operator briefings of 2026-08-31, whose decisions are restated here in full because they are now distributed across eight filings."
brand: plain
standard-margins: true
---

# What this plan is for

The operator filed two briefings on 2026-08-31: one specifying how bespoke apps
become installable, updatable, uninstallable packages, and one recording the
marketplace design so its decisions survive until the marketplace is wanted.

The first has been decomposed into **eight phases, SM715 to SM722**, each an
independently deliverable filing with its own outcome test. The second is
preserved intact as **SM723**, unbuilt.

**The intent is to chip away at these alongside ordinary releases**, rather than
to stop and build a feature. This document exists so that a phase landing three
releases after its predecessor still lands into a plan somebody can read.

# The sequence

| Phase | Filing | Delivers | Depends on |
| --- | --- | --- | --- |
| 1 | SM715 | The manifest: `owns`, `requests`, ancestry, reserved seed columns, and the inert slots | - |
| 2 | SM716 | The namespace register: admission, entries, tombstones | 1 |
| 3 | SM717 | Seeding: reference vs example, stable keys, dry-run, bulk files | 1, 2 |
| 4 | SM718 | The install flow: roles onto groups, path grants, connector bindings, plugin state | 1, 2 |
| 5 | SM719 | Updates: add-only, and a refusal naming what is blocked | 1, 2, 3 |
| 6 | SM720 | Declarative migrations: a fixed vocabulary | 5 |
| 7 | SM721 | Uninstall, reinstall reattachment, fork migration | 1, 2 |
| 8 | SM722 | **The manual round trip, then the packaging functions its log specifies** | 1-5, and uninstall/reinstall from 7 |
| - | SM723 | The marketplace design record - **DO NOT BUILD** | 8 |

## Critical mass is SM722, not SM721

**Phases 1 to 3 produce nothing an operator can see.** They are schema, a
register and a loader. It is worth saying that plainly at the start, because
three consecutive releases carrying invisible work is exactly when a plan gets
questioned.

**Phase 4 is the first visible output.** **Phase 8 is critical mass** - the point
at which apps are actually portable and the work can be announced.

Two phases are deliberately **not** on the critical path and can slip past
critical mass without holding anything up:

- **SM720** (declarative migrations). Add-only covers the common case; the
  vocabulary can follow.
- **Fork migration**, the second half of SM721. Its uninstall and reinstall
  halves *are* needed by the round trip; the fork half is not.

## A shortest path, if the schedule tightens

**SM715 → SM716 → SM717 → SM718 → SM719 → SM721 (uninstall/reinstall only) →
SM722.** That reaches critical mass with SM720 and fork migration outstanding,
and neither leaves anything broken.

# The decisions that are settled

Taken with the operator on 2026-08-31 and **not open for redesign during
implementation.** Restated here in full because they now sit across eight
filings, and a decision that is only recorded in the phase that first needed it
is a decision the next phase will reopen.

Namespace is identity
: Claimed at creation, permanent, never re-available. A fork is a different app
  and claims a new namespace. A conflict at install is a refusal, never a
  rename.

Data belongs to the installing instance
: Schema and seed data are granted irrevocably at install. Uninstall keeps every
  table. The author cannot take data back by licence change, deprecation or
  delisting.

Operators may modify anything
: An installed app is the operator's to edit. Editing taints the package as a
  *derived* state, never a flag. Divergence is the raw material of future forks.

Roles, not groups
: An app never names a group. It declares roles in its own vocabulary; install
  maps each to an existing group or creates one.

No app pseudo-users
: Apps are not principals in the user or group stores. Extra filesystem reach
  goes to the mapped groups through the existing ACL layer. Audit entries name
  the human who acted; attribution to the app is by path.

Add-only is the safe default
: An update inserts seed rows whose stable key is absent and does nothing else.
  Anything more is a declared migration or a refusal.

Refusals are visible
: An update the safe path cannot perform is refused, the app stays on its
  version, and the apps list says *update available* with what is blocked and
  why.

An app installs at a reserved path
: `_apps/<namespace>/` under the docroot. The manifest declares the namespace;
  the path follows and an author does not pick it. **The reason is collision
  with the operator's own content** - a free-choice subfolder takes `/shop` or
  `/events`, and the collision is found by an operator whose page has been
  shadowed. `_apps/` is a new reserved root, not `lazysite/`, because the
  existing reserved tree is not served as content and an app's pages must be.

App installation state is file-based
: The namespace register is a file in the reserved tree, **not** a table under
  the data plugin. A plugin-held register is unreadable exactly when a dormant
  plugin makes install need it (SM675), and an install system that fails on a
  fresh instance fails in the case it exists for. App **tables** remain the data
  plugin's; the record of what exists is readable without it.

An app has no server-side code
: It reaches the server only through `lazysite-data.pl`, the control API and the
  form handlers. **No phase weakens this**, and the one place it would be
  tempting - an escape hatch in the migration vocabulary (SM720) - is refused by
  name there.

# Associated items, and how each touches the plan

## Genuine dependencies

**SM579** - the reusable, credentialed connector. Already named by the release
manager as the next major feature after 0.11.8. **SM718's connector-binding half
cannot be built without it.** Until it lands, an app requesting a connector is
refused *naming SM579* - the manifest slot still exists and still validates.

**SM594** - form definition is manager-UI-only, and partial. The manifest's
`owns` carries form registrations. **If a form can only be defined through the
UI, install cannot apply one from a package.** This needs verifying before SM718
is scheduled; if no non-UI definition path exists, SM594 is a hard prerequisite
rather than a related item. Its general remedy runs through SM662's derivation
work.

**SM675** (a dormant capability refuses before it reads grants) is shipped and is
why SM718 checks plugin state. It also bears on SM716's open storage decision: a
register held in a data-plugin table would be unreadable exactly when a dormant
plugin made install need it.

**SM682** (mapping roles onto groups requires `manage_users`) is shipped and is
SM718's gate.

**SM578** (a rule copied twice will disagree with itself) is why SM717 must check
for an existing operator-facing import before writing a seed loader.

## The horizon these slots are held open for

**SM221** (realtime proxy daemon) and **SM666** (the persistent runtime is the
product, transports are plugins). The manifest's trigger, timer and realtime
slots exist from SM715 and are consumed by nothing until these land.

This is the plan's least intuitive instruction and the one to defend: **the slots
go in while the population is empty.** SM723 exists largely to establish that.
**SM222** (service lifecycle) and **SM485** (notification endpoints) sit in the
same horizon.

## Touches the design, decide before it bites

**SM611** - a table belongs to a site, not to the instance. Unbuilt. If table
ownership becomes per-site, **a table-prefix collision becomes a per-site
question rather than a per-instance one**, which is SM716's admission check.
Build the register so that answer can change without rewriting it.

**SM430** (common functions across the four surfaces) is the general form of
SM594's problem: install must work from more than the manager UI.

**SM657** (a row has nowhere to record a why) is adjacent to SM717's provenance
columns and worth reading before that phase, in case one mechanism serves both.

**SM497** (other database engines behind the adapter) is parked. App tables would
inherit whatever it decides; nothing here should assume SQLite specifics.

# Open items - the operator decides, not the implementer

**Resolved 2026-09-01**: register storage is a file in the reserved tree, and an
app installs at `_apps/<namespace>/`. Both are in the settled list above.


Each is named in its phase and repeated here so none is answered by default.

| Item | Phase | Note |
| --- | --- | --- |
| The bulk-seed size cap (a number) | SM717 | Above it, the data is the operator's to import |
| Whether an operator-facing data import already exists to reuse | SM717 | Answer **before** estimating the phase |
| Publisher-prefixed namespaces | SM715 | Deferred; does not alter the design |
| Who may file an advisory besides the catalogue operator | SM723 | Later |
| Whether a certified rung for apps reuses `lazysite-compliance.pl` | SM723 | Later |

# How to read progress

Each phase carries its own outcome test, and each is landable on its own. The
plan is on track when every landed phase's outcome test passes and the next
phase's dependencies are all shipped.

**The plan is not on track merely because phases have landed in order.** The one
check worth making at each landing: can the exemplar app - the messiest one -
still be described by what exists? That question is what SM722 answers
expensively, and asking it cheaply at every phase is how the expensive answer
stops being a surprise.
