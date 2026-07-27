---
title: "SM103 - recent-change markers and real-time presence"
subtitle: "A dot for what changed lately; later, live audit and change notifications"
brand: plain
status: partial
status-note: "phase 1 (recent-change markers) shipped in 0.6.1; OPEN: phase 2 real-time presence"
---

::: widebox
Small "changed recently" markers - a dot next to a nav item, a user, or a file that
was just edited - so an operator sees at a glance what moved since they last looked.
This is the visible tip of a larger real-time layer: streaming the audit trail and
notifying operators live when another user (or an agent) changes something.
:::

## Phase 1 - recent-change markers (cheap, no new transport)

- A dot / "edited 5m ago" marker on items changed within a window (e.g. 24h), driven
  by the data already in the **audit log** (it records target + timestamp + user).
- Surfaces where the operator already looks: the file manager (a dot on a recently
  changed page), the Users page (a recently changed account), the nav editor (nav
  changed). Tooltip: who and when.
- Implementation: a `recent-changes` API action returning `{target -> {ts, user,
  action}}` from the tail of the audit log; the existing pages poll it (or fetch
  once on load) and decorate their rows.

## Phase 2 - live audit stream

- Push audit events to an open manager page as they happen (Server-Sent Events is the
  simplest fit - one-way, proxy-friendly, no new infrastructure), so the Audit viewer
  and the markers update without a refresh.

## Phase 3 - presence and real-time notifications (the WebRTC comms system)

- Notify an operator when another user / agent changes something while they are in
  the manager ("alex-claude just edited /index.md"), and show who else is active.
- A WebRTC data channel (operator-to-operator, signalled through the site) is the
  ambition for low-latency presence and collaboration; SSE covers the
  server-to-client stream in the meantime, and the two can coexist.

## Notes

- Phase 1 is independent and bounded - it reuses the audit log and needs no new
  transport, so it can ship well before the streaming/presence layers.
- Ties to [[SM102]] (an agent feedback report is itself a recent event worth a
  marker) and to the audit work already shipped (every material change is recorded
  with target + actor + time, which is exactly the data these markers need).

## Status

**Phase 1 done (0.6.1; Groups surface added in 0.10.1 edge).** A `recent-changes`
control-API action returns `{ target -> { ts, user, action } }` for changes within a
window (default 24h), aggregated latest-per-target from the audit-log tail
(`_audit_cached_entries`), ok entries with a non-empty target only. The Files page
and the Users page fetch it on load and show a small dot next to a recently-changed
row, with a tooltip of when / who / what. The redirect target matching is exact: a
file row's `path` is the audit target for its save, and a user row's name is the
audit target for `user-*` events.

0.10.1 edge (branch claude/sm103-recent-change-markers) extends the same marker to
the **Groups page**: a group's settings / capability change audits under the group
name (a membership change audits as `user@group` and shows on that user's row
instead), so a dot by the group name catches it - the exact `recentDot` helper the
Users page uses, wired through `loadGroups`. The **nav editor** remains the one
Phase-1 surface named in the spec that is not yet decorated (its target is per-host,
`nav` / `nav (host)`), a small further extension.

Phases 2-3 (SSE live stream, then WebRTC presence) remain a larger real-time
programme to scope separately - and a true SSE stream is a poor fit for the CGI
model (a long-lived stream holds a web-server worker per open page), so it needs its
own transport design rather than a quick add.
