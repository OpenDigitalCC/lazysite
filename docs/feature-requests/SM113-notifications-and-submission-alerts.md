---
title: "SM113 - notification system + unreviewed-submission alerts"
subtitle: "Tell an operator when something needs attention; let plugins raise notices"
brand: plain
---

::: widebox
A first concrete need - alert an operator when form **submissions** have arrived or
changed since they last looked (new enquiries waiting, unreviewed) - implies a small
**notification system** the manager surfaces and that **plugins can raise into**. The
submission case is the first producer; the system is the reusable part.
:::

## The concrete case

- The forms/submissions plugin records when submission files change. If enabled in the
  plugin's config, the manager shows a notice ("3 new submissions since you last
  viewed") - driven by comparing the submissions' change time against a per-operator
  "last viewed" marker.
- Enabling it lives in the plugin config (opt-in), so notifications are a plugin
  capability, not always-on.

## The reusable system (what it implies)

- A **notifications channel** the manager reads: a badge/count in the header or
  sidebar, and a list (what changed, when, a link to act). Likely backed by a small
  store (per-operator unread state) plus producers that append notices.
- **Plugins raise notices** through a documented hook/endpoint (e.g. a plugin writes a
  notice with a type, target, message, timestamp); the manager aggregates and shows
  unread counts. This generalises beyond submissions (a failed build, an expiring
  credential, an audit anomaly could all notify).
- Ties to [[SM103]] (recent-change markers / real-time): the markers are the passive
  form, notifications the active "needs attention" form; both read the same change
  data and could share the SSE stream when that lands.

## Open questions

- Per-operator vs site-wide unread state; where it is stored.
- Push vs poll (poll for v1; SSE later per SM103).
- The plugin-facing API for raising a notice, and how it is gated.
- Dedup / expiry of notices.

## Status

Queued - design. Phase 1 could be just the submission badge (compare submission mtime
to a per-operator marker, shown when the plugin enables it); the general notification
store + plugin hook is the larger piece to scope with [[SM103]].
