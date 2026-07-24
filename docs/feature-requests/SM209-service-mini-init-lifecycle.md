---
title: "SM209 - Service/plugin lifecycle: a mini-init with independent start/stop/status"
subtitle: "enabled/disabled conflates DECLARED INTENT (config) with RUNTIME AVAILABILITY. Separate the two: give each service/plugin an init-style start/stop/status lifecycle, managed by a controlling process, so a plugin can be literally stopped (or never started) independently of its enabled config."
brand: plain
status: candidate
status-note: "LOGGED 2026-07-24 at user request - concept capture for later scoping, NOT implementation. Grounded in the current code (config-flag-only gating, no runtime lifecycle) but deliberately not fully designed; the stateless-CGI question (what 'running' means) is the first thing to resolve at scoping."
---

# SM209 - Service/plugin lifecycle: a mini-init with independent start/stop/status

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
