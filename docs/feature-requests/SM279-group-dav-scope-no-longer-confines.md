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

So the replacement looks deliberate and complete on the enforcement side. What
was left behind is everything that ADVERTISES the old mechanism:

- `group-set GROUP dav_scope PATH` accepts and stores it.
- `settings USERNAME` prints `dav_scope: (unset - set on a group)`, which tells
  the reader the setting exists and where to set it.
- `group_scopes` / `group_home_domain` remain exported.
- The processor keeps a module-free copy (`_group_scopes`) and does use it, for
  render-time rooting - so the field is not entirely inert, which makes this
  harder to reason about, not easier.

## Why it matters

An operator confining a client's editors by the documented CLI gets a stored
setting, a success message, and no confinement on any channel they care about.
This is the same shape as the two defects fixed alongside it ([[SM278]]): the
product reporting that it did something it did not do. It is worse than those
two because the thing not done is an access-control boundary.

**Not claimed:** that any live site is currently exposed by this. Sites confined
by the domain-access model are confined. This is about the OTHER route still
being offered.

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
