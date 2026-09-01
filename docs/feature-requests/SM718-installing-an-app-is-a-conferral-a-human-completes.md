---
id: SM718
title: "SM718: installing an app is a conferral, and a human completes it"
subtitle: "Phase 4 of the apps portability plan. Roles mapped onto groups, path prefixes granted through the existing ACL layer, connectors bound one at a time, and a plugin-state check that refuses rather than completing into a non-functional app."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 4 of 8.** Depends on SM715 and SM716. **This is the first phase whose
output an operator can see**, and it is where the plan stops being schema work.

# What this phase delivers

## The role mapping flow

Each declared role is presented with **create-new as the default** and
map-to-existing as the deliberate alternative. When mapping to an existing
group the screen shows **what that group already holds and how many members it
has**.

Widening a busy group is the realistic mistake, and it must be visible at the
moment it is made - not discoverable afterwards on the Groups page.

## The gate

Mapping roles onto groups changes who may write, so **SM682's ruling applies:
completing an install that maps roles requires `manage_users` alongside the
install capability.**

**An agent may propose an install; a human holding the right grants completes
it.** That sentence is the phase's acceptance criterion as much as any test.

## Path grants

Filesystem path prefixes outside the app's own subfolder are granted as ACL
entries **to the mapped groups**, through the existing ACL layer, each with the
reason the manifest stated, and recorded in the register.

No new permission mechanism. If one appears to be needed, that is a finding to
report rather than build.

## Connector bindings

Binding is a **per-connector operator act**, following the `bind_form`
precedent, and a public connector binding gets its own confirmation.

**This half depends on SM579**, which the release manager named as the next
major feature after 0.11.8 and which holds the reusable, credentialed connector
this would bind to. Until SM579 lands, the manifest declares connector requests
and install **refuses an app that requests one**, naming SM579 as the reason.
A refusal that names what is missing is the correct interim behaviour; silently
installing an app whose connectors do nothing is not.

## Plugin state

**SM675 established that a dormant capability refuses before it reads grants.**
A fresh instance may have the data plugin off, so install checks plugin state
and **refuses or offers to enable - never completes silently into a
non-functional app.**

# Related, and to verify before estimating

- **SM594** (form definition is manager-UI-only) is partial. The manifest's
  `owns` carries form registrations, and if a form can only be *defined* through
  the manager UI then install cannot apply one from a package. **Verify whether
  a non-UI definition path exists** before this phase is scheduled; if it does
  not, SM594 becomes a hard prerequisite rather than a related item.
- **SM430** (common functions across the four surfaces) is the general form of
  the same question.

# Outcome test

- An install mapping a role to an existing group, attempted by an account
  holding install but **not** `manage_users`, is refused - and the refusal names
  the missing capability, not just the action (SM712).
- The same install by an account holding both completes, and the register
  records the mapping.
- Mapping to an existing group displays that group's held capabilities and
  member count before confirmation.
- An app requesting a connector is refused while SM579 is unbuilt, naming it.
- An app needing the data plugin, on an instance where it is off, is refused or
  offered the enable - never installed inert.
