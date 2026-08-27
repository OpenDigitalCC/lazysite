---
title: "SM209 - Service/plugin lifecycle: a mini-init with independent start/stop/status"
subtitle: "enabled/disabled conflates DECLARED INTENT (config) with RUNTIME AVAILABILITY. Separate the two: give each service/plugin an init-style start/stop/status lifecycle, managed by a controlling process, so a plugin can be literally stopped (or never started) independently of its enabled config."
brand: plain
status: superseded
status-note: "SUPERSEDED by SM222 (2026-08-08). SM222 is the full design of the same feature, written after verifying the code, and it now carries this note's distinct contribution: the split between declared intent (config, durable) and runtime availability (transient, pausable without rewriting config), as a desired/runtime pair with paused defaulting to up so existing sites need no migration. SM209's controlling-process proposal is recorded in SM222 as considered and declined - a supervisor owning units that are mostly per-request CGI has nothing to own, and for the one real process it would compete with systemd. The dependency question SM209 raised is recorded there as open. Nothing is lost by reading SM222 alone."
---

# SM209 - Service/plugin lifecycle: a mini-init with independent start/stop/status

**This request is superseded by [SM222](SM222-service-lifecycle-mini-init.md).**
Read that instead - it is the same feature, designed against the verified code,
and it carries everything below that still stands. This document is kept only so
the reasoning that led here is not lost.

## What of this survives, and where

The intent-versus-availability split - the core of this note - is now SM222's
"Intent and availability are two surfaces, not one", including the back-compat
default and the requirement that a paused unit says why.

The controlling-process proposal is recorded in SM222 under "What this must NOT
become", as considered and declined with the reason.

The dependency question is recorded in SM222 as open, deliberately unanswered.

## Original note (2026-07-24), retained


## Why

Today a service or plugin has exactly ONE surface: an `*_enabled` config flag,
checked per request. `webdav_enabled`, `control_api_enabled`, `mcp_enabled`,
`oauth_enabled`, `token_exchange_enabled` gate the remote services
(`Lazysite::Capabilities` maps each capability channel to its flag); plugins gate
their own capabilities on an `enabled` setting. Disabled => the surface 404s /
returns `service_disabled`. There is **no runtime lifecycle** - no start, stop, or
status; no notion of "enabled but currently stopped".

That single surface conflates two different things:

- **Declared intent** (config): "this site is configured to offer MCP." A durable
  operator decision, edited in Settings -> Services.
- **Runtime availability** (state): "the MCP surface is up right now." An
  operational condition that an operator or the system might want to toggle
  WITHOUT rewriting config - e.g. stop a misbehaving plugin, pause a service
  during maintenance, or hold a service down until a dependency is ready, then
  bring it back up - none of which should mean "the operator disabled it".

## What (concept)

Refactor service/plugin management toward a **mini-init model**: each service and
plugin is an independently controllable unit with a small, uniform lifecycle,
managed by a controlling process, with the two surfaces separated:

- **start / stop / status** - the runtime surface. Stop a running unit; start a
  stopped one; query its current state. A unit can be "enabled but stopped" or
  "not started". Status reports the actual condition, not just the config flag.
- **enable / disable** - the config surface, unchanged in meaning (durable intent,
  survives restarts). Disabled units are not started; enabled units are eligible
  to run.
- A **controlling process** owns the lifecycle - it starts enabled units, honours
  explicit stop/start, exposes status, and is the single authority for what is
  actually running (rather than every CGI invocation independently re-deriving
  availability from a flag).

The effective availability of a surface becomes `enabled AND started`, and both
are separately inspectable and controllable.

## Open questions (resolve first at scoping)

- **Stateless CGI:** lazysite services are largely per-request CGI, so "running"
  is not a live process today. What does start/stop/status MEAN here - a control
  file / state the request path consults (a soft stop), a supervised worker
  (the SM139 pool unit / worker services referenced in the processor), or both
  depending on the service? This is the crux and shapes everything else.
- **The controlling process:** is it a new supervisor, or an extension of the
  existing pool/worker unit? How does it persist and report state?
- **Surface split in the manager:** the Services page grows a status + start/stop
  control alongside the existing enable/disable toggle; the control API / MCP gain
  status (read) and start/stop (write, audited) actions - which capability governs
  them (`manage_config`?).
- **Dependencies:** should a unit be startable only when its dependencies are up
  (e.g. a form plugin needing SMTP config), giving a real reason a unit is stopped?
- **Back-compat:** existing sites only have the enabled flag; a missing runtime
  state must default to "started when enabled" so nothing changes for them.

## Scope note

Logged for later design. NOT to be implemented off this note. The first work item
is a short design spike answering the stateless-CGI question above; only then is
the surface split + controlling-process design worth drafting.
