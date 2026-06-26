---
title: "SM107 - Manager access groups as a group picker"
subtitle: "Choose existing groups instead of typing names"
brand: plain
---

::: widebox
On the Config page, **Manager access groups** (`manager_groups` in lazysite.conf -
membership of any of these makes an account an operator) is a free-text field. It
should be a picker over the **existing groups**, multi-value, so an operator selects
real groups rather than typing names that must match exactly.
:::

## Why

`manager_groups` is security-critical (it grants full operator access), and a typo
silently grants nobody or the wrong group. The manager already knows every group;
the field should offer them.

## Shape

- Config page (`starter/manager/config.md`): give the `manager_groups` field a new
  field type, e.g. `groups` (multi-select), populated from the `groups` API the Users
  page already uses.
- Multi-value: it holds a set of groups, stored as the existing comma/space-separated
  string in lazysite.conf, so the backend format is unchanged.
- Render as a checklist or a multi-select of existing groups, with the current value
  pre-ticked; optionally allow a free-text add for a group that does not exist yet
  (creating it on first membership).

## Notes

- Pairs with [[SM095]] (group-based capabilities) and the Users-page operator note
  (SM094) - all three lean on groups being first-class and pickable.
- Keep a guard: do not let the operator save an empty `manager_groups` if that would
  lock everyone out (the doctor already warns when it is unset).

## Status

Queued. Bounded: a new `groups` field type in the config-page renderer plus a fetch of
the group list; backend storage format unchanged.
