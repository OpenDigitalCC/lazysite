---
title: "SM682: an external user can write its own rows, or hold instance-wide data administration, and there is nothing in between"
subtitle: "Apps agent, 2026-08-28, from the learning-app build: 'it blocks safely shipping the learning app's submission flow to external learners' - and it is the capability boundary, not the feature"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING), both halves. `write_data` permits row insert/update/delete on tables whose `writable_by` names one of the caller's groups and nothing else - no data-table-save, no data-migrate, no data-table-drop, no reach into a table that does not name them. THE ASYMMETRY IS THE DESIGN: for manage_data the list NARROWS (unchanged); for write_data it is an ALLOW-LIST and a table naming nobody is closed, or the capability would be instance-wide write under a new name. SECOND HALF: changing `writable_by` now requires manage_users as well as manage_data - SM647's ruling applied to the descriptor, closing the residue where a data agent widens a group the operator already trusted with write_data elsewhere. Only a CHANGE is gated, compared as a normalised string so a reorder is not one, and read with the same YAML loader the save uses so the two cannot disagree. Sabotage-verified five ways across both halves. VERIFIED WITH THE FINGERPRINT (SM662): four gates moved and no others - the two row verbs on each table, plus the three deliberately-constant introspection gates. The fingerprint itself had to be fixed first; it is recorded on SM662."
---

# The gap, as measured

Writing a row over the data endpoint requires `manage_data`. That capability
also carries table create, alter and drop (`data-table-save`, `data-migrate`,
`data-table-drop`) and read AND write across EVERY table on the instance.

Verified by the reporter on 0.11.1: a learner without `manage_data` POSTing a
row gets `403 this account does not hold manage_data`. Reads are unaffected - a
signed-in user reads a private table without it. The gap is the write path
specifically.

So an app with external, semi-trusted users has two options and both are wrong:
hand instance-wide data administration to the least-trusted user class, or
collect nothing.

# `writable_by` cannot be the answer, and the code says why

The filing's second shape - make membership of `writable_by` a positive grant -
is already argued against in `lazysite-data.pl`, at the gate itself:

> NARROWING ONLY, deliberately. Widening - letting a listed group write WITHOUT
> manage_data - would make a YAML file a grant of capability, and that file can
> be written over MCP by an agent holding manage_data. An agent could then hand
> write access to a group it chose.

That reasoning holds. `data-table-save` is gated on `manage_data`, so any agent
holding it can edit a descriptor; if the descriptor granted capability, that
agent could grant write to any group it named. The list must not be a grant.

# The shape that survives it

A narrow capability - `write_data` - granted the way every capability is: from
the group store, by an operator, under SM195's conferral ceiling. It permits row
insert, update and delete and nothing else. No `data-table-save`, no
`data-migrate`, no `data-table-drop`.

**And `writable_by` means something DIFFERENT for it.** This is the part the
filing does not say and the part that makes it safe:

| Caller holds | `writable_by` empty | `writable_by: [learner]` |
|---|---|---|
| `manage_data` | may write (unchanged) | may write only if in the list (unchanged) |
| `write_data` | **may NOT write** | may write if in the list |

For `manage_data` the list NARROWS, as today. For `write_data` it is an
ALLOW-LIST: a holder may write only tables that name one of its groups, and a
table naming nobody is closed to it. Otherwise `write_data` would be
instance-wide write by another name, which is the thing being fixed.

The YAML is then not a grant. It cannot give write to anybody who does not
already hold `write_data`, and `write_data` comes from the group store where an
operator put it.

# The residual escalation, and the precedent for closing it

An agent holding `manage_data` can still add a group to a descriptor's
`writable_by`. It cannot invent `write_data`, so it can only widen a group that
an operator has ALREADY trusted with row-writes elsewhere - a much smaller step
than the one this filing is about, but not nothing.

SM647 answered exactly this question one object over, this week: writing a
domain's `allowed_groups` decides WHO may reach that domain's content, so it now
requires `manage_users` as well as `manage_domains`. The same argument applies
to `writable_by`, and the same remedy is available: editing it requires
`manage_users` in addition to `manage_data`.

Recommended, and cheap once `write_data` exists - it is the SM647 pattern
applied to the descriptor instead of the domain row.

# What it costs

A new capability is the six-place change SM662 is about: `%need`, `%COOKIE_CAP`,
`@CAP_KEYS`, `effective_settings`, `Capabilities.pm`'s `unlocks` and its
description, `lazysite-check.pl`'s list, the Groups grid labels, and the two
generated documents. Several of those are caught by gates rather than by
reading - SM633 and SM652 each hit six, SM664 hit six this release.

`tools/gate-fingerprint.pl` (SM662, shipped in 0.11.4) makes that safer than it
was: the resolved answers of every gate can be diffed before and after, so a
new capability that changes an EXISTING gate's behaviour shows up as a column
that moved.

# The interim the reporter proposes

Routing submissions through a gated native form handler - insert-only, a row per
save, the app reading the latest - keeps `manage_data` off the learner group at
the cost of edit UX. It is a sound fallback and it inherits the forms pipeline's
anti-abuse (SM673 makes the same argument for registration). Worth saying
plainly: it is not a worse design, it is a different one, and if the schedule
demands it the app is not compromised by taking it.

# Related

[[SM647]] (writing an access list requires authority over the thing it names -
the precedent for the `writable_by` half), [[SM662]] (the six-place cost, and
the fingerprint that makes it safer), [[SM611]] (a data table should belong to a
site - the other half of who may reach a table), SM577 (an instance-wide store
is not scoped by the grant that reached it).

# Not started
