---
id: SM716
title: "SM716: the namespace register admits an app, and remembers it after it leaves"
subtitle: "Phase 2 of the apps portability plan. A record and an admission check, not an allocator - and the tombstone that keeps a retained table identifiable once the app that created it is gone."
brand: plain
standard-margins: true
status: candidate
---

# Where this sits

**Phase 2 of 8.** Depends on SM715 (an app has an identity to record).
Phases 3, 4, 5 and 7 all depend on this.

# What this phase delivers

A store recording every namespace the instance has ever installed.

## What an entry claims

Namespace, subfolder path, table prefix, app version, install date, the
role-to-group mappings made at install, ACL grants made for it, connector
bindings approved for it, and the seeding record - that seeding ran, when, and
from which version.

## What it enforces at install

The namespace is unused here, the subfolder does not collide, and **the table
prefix collides with neither a live table nor any tombstone's tables**. A
conflict refuses with the reason named.

## The tombstone

At uninstall the entry becomes a tombstone: namespace, app identity, final
version, uninstall date, and the list of retained tables.

**Tables outlive the install.** The tombstone is what keeps them identifiable
and keeps the prefix reserved, and it is what a later reinstall reattaches to
rather than colliding with.

# Why this is its own phase

The register is the thing every other phase writes to, and it is the only
component whose absence cannot be worked around by hand during the manual round
trip. It is also where the one storage decision lives, and that decision should
not be taken as a side effect of building something else.

# Decisions already settled - do not reopen

Data belongs to the installing instance
: Schema and seed data are granted irrevocably at install. **Uninstall keeps
  every table.** The author cannot take data back by licence change,
  deprecation or delisting. This is why the tombstone exists at all.

# Open items - the operator decides

- **Register storage: a file in the reserved tree, or a table under the data
  plugin.** Implementation prepares for either; **do not decide by default.**
  Note for whoever decides: a data-plugin table makes the register subject to
  the plugin's own enabled state, which SM675 established refuses before it
  reads grants - so a dormant plugin would make the register unreadable at
  exactly the moment install needs it.

# Related

- **SM611** (a table belongs to a site, not to the instance) is unbuilt and
  touches this directly: if table ownership becomes per-site, a prefix
  collision is a per-site question rather than a per-instance one. The register
  should be built so that answer can change without rewriting it.

# Outcome test

- Install records an entry; the same namespace refuses second time, naming why.
- A table prefix colliding with a **tombstone's** retained tables refuses.
- Uninstall converts the entry to a tombstone listing the retained tables.
- Reinstall of the same app reattaches to its tombstone rather than colliding.
