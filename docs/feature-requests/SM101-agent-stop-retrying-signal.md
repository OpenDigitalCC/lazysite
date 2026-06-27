---
title: "SM101 - a clear 'do not retry' signal so an agent backs off"
subtitle: "A permanent failure should tell the agent to stop, not invite another attempt"
brand: plain
---

::: widebox
An AI partner tried to edit the **active** layout (`layout.tt`) - forbidden (you
must switch away from a live artifact first, and it may lack `manage_layouts`) - and
**kept retrying** (edit, then copy_file, both failing). A permanent refusal should
signal "this will never succeed; stop and ask the operator", so the agent backs off
instead of hammering.
:::

## Observed

```
edit      /lazysite/layouts/default/layout.tt   fail
copy_file /lazysite/layouts/default/layout.tt   fail
```

The error already carries a machine-readable `kind` (`permission` / `blocked` /
`blocked-config`), but nothing tells the agent whether a retry is pointless.

## Shape

- Add a **`retryable: false`** field to tool errors whose `kind` is permanent
  (`permission`, `blocked`, `blocked-config`, `not-found` for a forbidden path,
  `invalid-path`, `exists`), and `retryable: true` only for genuinely transient ones
  (a held lock, a rate limit).
- Make the **message** explicit and imperative for the permanent cases, e.g.:
  *"Editing the ACTIVE layout is not permitted - switch to another layout first, or
  ask the operator. Do not retry."* and *"This path is outside your granted
  capabilities (need manage_layouts). Do not retry; ask the operator to grant it."*
- Surface the same in `whoami`/`get_permissions` so an agent can check *before*
  attempting (it already reports capabilities; make the "active artifact is
  read-only" rule discoverable).
- Optionally a short **back-off contract** in the connector tools doc: on
  `retryable:false`, stop and report to the human; only retry on `retryable:true`
  after the stated `Retry-After`.

## Why it matters

A clear non-retriable signal saves tokens and audit noise (repeated fail entries),
and turns a confusing loop into one actionable message the agent relays to the
operator.

## Status

**SHIPPED in v0.4.27.** (see CHANGELOG)


Queued. Bounded: a `retryable` flag + sharper messages on the existing error `kind`
taxonomy in `lazysite-mcp.pl`, plus a note in the connector tools doc and the
"active artifact is read-only" rule in `whoami`.
