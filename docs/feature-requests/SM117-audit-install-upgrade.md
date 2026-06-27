---
title: "SM117 - audit install / upgrade / version events"
subtitle: "Record deploys in the audit trail"
brand: plain
---

## What

The audit log should record installer activity:

- **installed** - a fresh install, with the version.
- **upgraded** - an upgrade, with the from -> to versions.
- (the running **version** is already shown in the footer and via the version action;
  the audit entry captures *when* it changed and to what.)

## Why

Raised 2026-06-27. Deploys are material events; right now the audit trail shows
content/auth/connector activity but not "the site was upgraded to X.Y.Z on this date",
which is exactly the context an operator wants when reading the log after a change.

## Shape

- `install.pl` (and the Hestia deploy wrapper) write an audit event at the end of a
  successful install/upgrade: action `installed` / `upgraded`, target the version
  (or `from->to`), origin `install`, user the deploying operator if known (else
  blank/`system`), via `Lazysite::Audit::audit_log`.
- Guard for the fresh-install case where `lazysite/logs/` may be created in the same
  run - write the event after the tree + logs dir exist.
- Keep it to one event per run (not per file), high-level.

## Status

Queued. Small: one audit_log call at the install/upgrade summary point, with the
version already in hand; mind the logs-dir-exists ordering on a fresh install.
