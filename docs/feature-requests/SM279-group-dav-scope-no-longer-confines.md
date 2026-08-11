---
title: "SM279 - A group's dav_scope is still accepted, still stored, and no longer confines anything"
subtitle: "The domain-access model replaced it. The CLI verb, the resolver and the help text all survived the replacement, so an operator can set a confinement that has no effect on the manager, WebDAV or MCP."
brand: plain
status: candidate
status-note: "FOUND 2026-08-11 while building the SM267 panel test, which needed a scoped manager and could not get one. NOT investigated beyond the observation below, and NOT fixed - deciding between 'restore the binding' and 'retire the verb' needs someone who knows which model is intended, and getting that wrong in either direction is a security change. Sized S if the answer is retire, M if it is restore."
---

# SM279 - a group's `dav_scope` no longer confines

## What was observed

On a clean docroot:

```bash
lazysite-users.pl --docroot D group-set clientb dav_scope other
lazysite-users.pl --docroot D group-set clientb ui 1
lazysite-users.pl --docroot D add bob pw
lazysite-users.pl --docroot D group-add bob clientb
```

`groups-settings.json` then contains, correctly:

```json
"clientb": { "dav_scope": "/other", "label": "clientb", "ui": 1 }
```

And `settings-get` for bob returns:

```json
"dav_scopes": [], "groups": ["clientb"]
```

The manager API, WebDAV and MCP all confine on `dav_scopes`. Empty means
unconfined. So bob is unconfined, with a scoped group.

## Why

`Lazysite::Auth::Settings::group_scopes` reads `dav_scope` off the group and
still works. Nothing on the manager/DAV/MCP path calls it any more:
`resolve_user_scopes` resolves scopes from the **domain-access** model
(`Lazysite::Auth::DomainAccess`), whose own header says it *"replaces the
per-group dav_scope of SM155"*.

The replacement is deliberate, complete on the enforcement side, and on the
security record. `docs/SECURITY.md` carries it as an accepted decision:

> **2026-07-18 - SM165: domain-owned access-control model (0.7.26)** - access
> confinement moved from a per-user/per-group `dav_scope` to a domain-owned
> model [...] enforcement code unchanged (only the SOURCE of `dav_scopes`
> moved).

So the intended model is not in doubt. What was left behind is everything that
ADVERTISES the old mechanism:

- `group-set GROUP dav_scope PATH` accepts and stores it.
- `settings USERNAME` prints `dav_scope: (unset - set on a group)`, which tells
  the reader the setting exists and where to set it.
- `group_scopes` / `group_home_domain` remain exported.
- The processor keeps module-free copies (`_group_scopes`, `_group_home_domain`)
  which are **defined and never called** - it roots the file browser from
  `_domain_scopes` / `_domain_home` instead.

**Corrected 2026-08-11**: an earlier draft of this filing said the processor
still used its copy for render-time rooting. It does not. `_group_scopes` is
dead code, so the field is inert on EVERY path - enforcement and rooting alike.
That makes the decision simpler, not harder.

## Why it matters

An operator confining a client's editors by the documented CLI gets a stored
setting, a success message, and no confinement on any channel they care about.
This is the same shape as the two defects fixed alongside it ([[SM278]]): the
product reporting that it did something it did not do. It is worse than those
two because the thing not done is an access-control boundary.

**Not claimed:** that any live site is currently exposed by this. Sites confined
by the domain-access model are confined. This is about the OTHER route still
being offered.

## The window

The migration shipped in **0.7.26 on 2026-07-18**. Every release since -
0.8.x, 0.9.x, 0.10.x - has accepted `group-set GROUP dav_scope PATH`, stored
it, and confined nobody. An operator who used it in that window has a user they
believe is confined and who is not.

This is checkable without a decision and should be checked first: any group
carrying `dav_scope` in `groups-settings.json` is either a live confinement gap
or a stale value that should be cleared.

## The decision to take first

**If the domain model is the intended one**: retire the group `dav_scope` verb -
refuse it with a message naming the replacement, drop the `settings` line that
points at it, and decide separately what the processor's `_group_scopes` copy
should read. Small, and it removes a false affordance.

**If group binding is still meant to work**: `resolve_user_scopes` should union
`group_scopes` with the domain-derived scopes. Larger, and it needs its own
tests on all three channels, because a scope union is exactly where a widening
bug hides.

Either way the CLI and `settings` output must stop describing a mechanism that
does not do what they say.

## Related

[[SM155]] (which moved the binding onto groups), [[SM158]] (the domain-access
model that replaced it), [[SM278]] (the same failure shape, fixed).
