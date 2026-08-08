---
title: "SM222 - Mini init: a uniform start / stop / status contract for services and plugins"
subtitle: "Make 'off' actually off rather than a refusal from a process that still ran, give every service and plugin the same lifecycle verbs, and make status report enough to act on"
brand: plain
status: candidate
status-note: "Design + analysis written 2026-07-27 at the operator's request. NOT built. SUPERSEDES SM209 (merged 2026-08-08): SM209's intent-versus-availability split is absorbed as a third state (desired/runtime, paused defaulting to up so back-compat is free), and its controlling-process proposal is recorded as considered and declined. Key finding: a disabled service is NOT fully off today - the web server still routes to it and the CGI still spawns, reads the conf and only then refuses (404), and the refusal contract is inconsistent (token-exchange answers 200 {ok:0,code:service_disabled} where the others 404). Recommends generalising the content-history health verdict vocabulary, which already proves the model. Explicitly does NOT propose a process supervisor - systemd keeps that job."
---

# SM222 - mini init (service + plugin lifecycle)

## Why

lazysite has services (WebDAV, control API, MCP, OAuth, token exchange, the
manager) and plugins (stats, form-handler, content-history, ...). Between them
there is no shared answer to three questions an operator asks constantly:

- **Is it on?** - answered differently per surface, and only as a config flag.
- **Is it actually working?** - answered for exactly one plugin
  (content-history) and, partially, by a CLI tool.
- **What happens when I turn it off?** - answered "it refuses", which is not the
  same as "it is off".

The operator's requirement is precise: services should have **stop / start /
status**; when off they should be **fully off**; and status should **report more
data**. It should cover the system services **and plugins where appropriate**.

## What is true today

### Services and their killswitches

| Service | Entry point | Config key | Default |
|---|---|---|---|
| Manager UI | pages under `/manager/` | `manager` | off |
| WebDAV | `lazysite-dav.pl` | `webdav_enabled` | off |
| Control API (token path) | `lazysite-manager-api.pl` | `control_api_enabled` | off |
| MCP connector | `lazysite-mcp.pl` | `mcp_enabled` | off |
| OAuth 2.1 | `lazysite-oauth.pl` | `oauth_enabled` | off |
| Token exchange | `lazysite-auth.pl` | `token_exchange_enabled` | off |

`Lazysite::Util::service_enabled($docroot, $key)` is the single reader (a
single-pass scan of `lazysite.conf`, truthy on
`enabled|true|yes|on|1`), and `channel_service()` in
`lib/Lazysite/Capabilities.pm` is the canonical channel-to-killswitch map that
the permission grids and `action_channel_services()` already consume. That part
is in good shape and should not change.

### "Off" is an application-layer refusal, not an off switch

This is the gap the request names, and it is real. `lazysite-dav.pl` reads the
conf and returns 404 **from inside the CGI** - so on every request to a disabled
service the web server still routes, a process still spawns (or an FCGI worker
is still occupied), the config is still read, and only then is the request
refused. The endpoint remains mapped: the vhost generators
(`tools/lazysite-{nginx,apache}-vhost.pl`) route `/cgi-bin`, `/dav`, `/manager`
and friends **unconditionally**, because they know nothing about killswitches.

Consequences: a disabled service still presents an attack surface (the script is
reachable and parses input before refusing), still costs a process spawn per
probe - and scanners probe `/dav` and `/.well-known/*` constantly - and cannot
be verified as off by any external observation stronger than "it says 404".

The one part that *is* genuinely off is **discovery**: `.well-known/ai-partner`
is built from live config and lists only enabled endpoints, and the OAuth
metadata 404s when `oauth_enabled` is off, before render or cache (SM190). That
is the right behaviour and the model for the rest.

### The refusal contract is inconsistent

WebDAV, OAuth and MCP return **404** ("this endpoint does not exist"), while
token exchange returns **200** with `{ok:0, code:'service_disabled'}` -
deliberately, to let a client distinguish "turned off" from "not installed".
Both behaviours are defensible; having both, undocumented, is not. An agent
cannot reliably tell a disabled service from a missing one.

### Plugins have enablement, not lifecycle

A plugin is enabled by appearing in the `plugins:` list in `lazysite.conf`
(`action_plugin_enable`/`_update_plugins_conf`), and may declare optional
`on_enable`/`on_disable` hooks naming its own actions. There is no status verb.
A failed hook does not undo the toggle - content-history's own descriptor notes
that "the plugin's own status action is the recovery surface", which is only
true for the one plugin that has one.

### One plugin already solves this properly

`Lazysite::Git::health()` returns a structured verdict that is exactly the model
worth generalising:

```
verdict: no-git | disabled | paused | inconsistent | degraded | ok
healthy: 0|1
plus:    git_available, conf_enabled, initialised, head_ok, readable,
         lock_present, recording_failed, commits
```

The valuable part is not the fields but the **vocabulary**: it distinguishes
*deliberately off* (`disabled`) from *off but with residue* (`paused`), from
*config says on but reality disagrees* (`inconsistent`), from *working but
impaired* (`degraded`). That four-way distinction is what "status should report
more data" actually means, and it already exists in the codebase, tested and
field-proven.

### Existing status reporting

`tools/lazysite-check.pl` probes install health (ownership, writable runtime
dirs, group bits, git readiness, system pages, discovery hygiene), prints
per-check `OK`/`WARN`/`FAIL` with remediation, exits non-zero on any FAIL, and
with `--fix` applies safe repairs and re-runs so the report shows post-fix state
(SM215). It is CLI-only and per-check; there is no aggregate verdict, no
programmatic endpoint, and no single manager surface answering "what is the
state of this install".

## Design

### The lifecycle contract

Every **managed unit** - a system service or a plugin - answers three verbs:

`status`
: Always available, never mutating, safe to call often. Returns the common
  shape below.

`start` / `stop`
: Move desired state. For a config-gated service this writes the killswitch (via
  the existing audited, flock-protected `_write_conf_key`) and performs the
  side-effects that make "off" real (below). For a plugin it is the existing
  enable/disable path plus its declared hooks.

Common status shape, generalising `Git::health`:

```
{ unit: "webdav",  kind: "service" | "plugin",
  desired:  "on" | "off",           # what the config says
  verdict:  "off" | "starting" | "on" | "degraded" | "inconsistent" | "failed",
  healthy:  0 | 1,
  message:  "one plain-language sentence",
  since:    <epoch>,                # last transition, from the audit trail
  by:       "<account>",            # who last changed it, from the audit trail
  detail:   { ... unit-specific evidence ... },
  remedy:   "what to do about it, when not healthy" }
```

`desired` vs `verdict` is the point of the whole design: the config records
intent, status observes reality, and **the interesting operator information is
the disagreement between them** - which is precisely what content-history's
`inconsistent` verdict already captures and what nothing else in the system
does.

### Intent and availability are two surfaces, not one

Absorbed from SM209, which this request supersedes, and it changes the contract
above rather than decorating it.

`start` / `stop` as described writes the killswitch - which makes them the same
act as enable / disable. That conflates two things an operator genuinely needs
apart:

Declared intent
: "This site offers MCP." A durable decision, edited in Settings, surviving
  restarts and upgrades.

Runtime availability
: "The MCP surface is up right now." An operational condition an operator wants
  to change **without rewriting configuration** - pause a service during
  maintenance, hold a misbehaving plugin down until it is fixed, keep a unit down
  until a dependency is ready.

Collapsing them means the only way to pause something is to disable it, and a
disabled unit is indistinguishable from one the operator never wanted. The
operator who paused MCP for twenty minutes and the operator who does not offer
MCP leave identical configuration behind, and the audit trail is the only place
the difference survives.

So availability is a third state, not a second spelling of intent:

```
desired:   "on" | "off"        # config. Durable. What the operator wants offered.
runtime:   "up" | "paused"     # transient. Defaults to "up" when absent.
```

Effective availability is `desired == on AND runtime == up`. `paused` is already
in the verdict vocabulary this design borrows from `Git::health`, so it costs
nothing to express.

Two consequences worth stating:

- **Back-compat is free.** Existing sites carry only the killswitch. Absent
  runtime state means "up", so an enabled service on an upgraded site behaves
  exactly as before and nothing needs migrating.
- **A paused unit says why.** The `message` and `remedy` fields already exist;
  a pause should carry a reason, because "paused" without one is the same
  mystery as "off" without one - which is the defect this whole request exists
  to fix.

Whether a unit may be started only once its dependencies are up (a form plugin
needing SMTP configuration, say) is a real question SM209 raised and this design
does not answer. It is a strictly better problem to have once `paused` carries a
reason, because "paused: waiting on smtp.conf" is a dependency check with no
dependency engine behind it. Resist building one until something demands it.

### Making "off" actually off

Three layers, which should be named explicitly because they are commonly
conflated:

L1 - application refusal (today)
: The CGI runs and refuses. Keep it: it is the semantic gate and the last line
  of defence, and it must stay correct even if L2 is misconfigured.

L2 - not routed (the recommended addition)
: The web server does not map the endpoint at all when the service is off. A
  disabled service then costs nothing, presents no parser to a scanner, and is
  externally indistinguishable from not installed. Implementation: the vhost
  generators emit the per-service `location`/`ScriptAlias` blocks into a
  **generated include** owned by lazysite, regenerated when a killswitch
  changes, with a reload hook. Trade-off, stated plainly: this **couples a
  config toggle to a web-server reload**, which is a genuine cost - it needs
  privileges the CGI does not have, so the toggle must either queue the change
  for a privileged helper or accept "takes effect on next regeneration". That
  trade-off is the main thing to decide.

L3 - not installed
: The script is absent or non-executable. Appropriate only for a surface an
  operator never wants; too blunt for a toggle.

Recommendation: L1 stays, L2 is added as the "fully off" guarantee with an
explicit, documented reload story, L3 is out of scope. Also **unify the refusal
contract** at L1 so every disabled service behaves identically (recommendation:
404 with no body detail for endpoint surfaces, and reserve the
`{ok:0,code:service_disabled}` JSON form for the API-shaped callers that need to
tell "off" from "missing" - documented either way, and tested).

### Applying it to plugins

Extend the `--describe` contract with an **optional** `lifecycle` block:

```
lifecycle: { status: "<action-id>", start: "<action-id>", stop: "<action-id>" }
```

- A plugin that declares `status` gets a real verdict; content-history becomes
  conformant essentially for free, since it already returns this shape.
- A plugin that declares nothing keeps working and is reported with a derived
  verdict from its enablement (`on`/`off`) - so this is additive, and no
  existing plugin breaks.
- `start`/`stop` default to the existing enable/disable plus `on_enable`/
  `on_disable`, so the verbs are uniform even when a plugin does nothing extra.
- The status action must be **read-only and cheap** - it will be called by the
  aggregate view, and a status probe that mutates or blocks is worse than none.

This also fixes the "failed hook leaves a lie" problem: if `on_enable` fails,
the unit records `verdict: failed` with the hook's error as `message`, instead
of the config claiming success while the plugin is inert.

### Surfacing it

One resolver, three consumers - no second source of truth:

- **Control API**: a `services-status` read action (capability: the existing
  `manage_config`, or read-only for any manager) returning the array of unit
  statuses. Naturally also an MCP read tool later, so an agent can answer "is
  this install healthy".
- **CLI**: `lazysite status`, the natural sibling of `lazysite check`. Where
  `check` audits install *correctness* (permissions, ownership), `status`
  reports service *state* - and the two should reference each other rather than
  overlap.
- **Manager**: a Services panel showing every unit with its verdict, last
  change and remedy - the "no unified status display" gap. The killswitch
  toggles on Site settings become the `start`/`stop` controls for the same
  units.

### What this must NOT become

**Not a controlling process.** SM209 proposed a supervisor owning every unit's
lifecycle and being the single authority for what is running. Considered and
declined: it is the same objection as below, one level up. A controlling process
that owns units which are mostly per-request CGI has nothing to own, and for the
one unit that IS a real process it would compete with systemd. The state file
plus an observed verdict gives the same operator answer without a daemon whose
own liveness then becomes a question.

**Not a process supervisor.** systemd already supervises the one real process
lazysite runs (`lazysite@.service`, the FastCGI pool) and would supervise
[[SM221]]'s daemon the same way. Mini-init's job for a process-backed unit is to
**report** its state (via `systemctl is-active`/`show`, read-only) and to own
the *config-level* start/stop - not to spawn, restart or babysit. Building a
second supervisor would duplicate systemd badly and create two answers to "is it
running". This boundary is the most important constraint in this document.

**Not a new config store.** Desired state stays in `lazysite.conf`, written
through the existing atomic, flock-protected, audited path. Status is computed,
never stored - a status cache would immediately become a third thing that can
disagree.

## Acceptance

- Every service and plugin answers `status` with the common shape; a plugin that
  declares no lifecycle block still reports a derived verdict rather than
  erroring.
- With a service off, an external request to its endpoint is refused identically
  across services, and (with L2) does not reach a lazysite process at all.
- A config-says-on-but-broken unit reports `inconsistent` with a remedy, rather
  than appearing healthy.
- A failed enable hook leaves the unit reporting `failed` with the hook's error,
  not a silent success.
- `lazysite status`, the control API and the manager Services panel agree
  because they call one resolver.
- Disabling a service never changes what a *disabled* service already returned
  to an authorised caller of another service (no cross-talk).

## Open decisions (for the operator)

1. **L2 routing**: accept the web-server reload coupling (and design the
   privileged helper), or keep "fully off" at L1 plus discovery-suppression
   only? This is the substantive call.
2. **Refusal contract**: standardise on 404 everywhere, or keep the
   `service_disabled` JSON for API-shaped surfaces? (Recommend the latter,
   documented and tested.)
3. **Scope of `start`/`stop` for plugins** - is a plugin's `stop` expected to
   quiesce its data (content-history's `paused` residue) or merely stop acting?
4. **Does `status` need a capability of its own**, or is it readable by any
   manager account? (It leaks which services exist and their health.)

Related: [[SM221]] (the real-time daemon, which should report through this
contract rather than inventing its own), SM142/SM139 (the systemd pool that
defines the process boundary), SM215 (`lazysite-check --fix`, the sibling
tool), SM180 (dormant capability indicators - a granted capability whose service
is off is the same disagreement this models), and SM190 (discovery that already
reflects live config correctly).
