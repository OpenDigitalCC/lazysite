---
title: "SM222 - Mini init: a uniform start / stop / status contract for services and plugins"
subtitle: "Make 'off' actually off rather than a refusal from a process that still ran, give every service and plugin the same lifecycle verbs, and make status report enough to act on"
brand: plain
status: partial
status-note: "PARTIAL 2026-09-05: THE CONTRACT IS BUILT. Lazysite::Lifecycle defines the common shape and the daemon is its first conforming consumer, which pays the debt SM666 recorded when it implemented desired-versus-runtime locally. The vocabulary is content-history's generalised rather than a new one; the verdict is derived in ONE place so units cannot drift apart on what inconsistent means; and a remedy is required whenever the verdict is not healthy, because SM712, SM730, SM749 and SM750 are four filings in one week about naming a state without naming an action. WHAT REMAINS: the existing services (WebDAV, control API, MCP, OAuth, token exchange) migrate one per SM, following ADR 0009 rather than one wide edit, since SM726 and SM728 both record what a wide simultaneous conversion costs. THE SUBSTANTIVE CALL IS UNTOUCHED: open decision 1, L2 routing, remains the operator's and did not bind the exemplar, because the daemon has no routed endpoint in phase 1. ORIGINALLY, and true until today: Design + analysis written 2026-07-27 at the operator's request. NOT built then. SUPERSEDES SM209 (merged 2026-08-08): SM209's intent-versus-availability split is absorbed as a third state (desired/runtime, paused defaulting to up so back-compat is free), and its controlling-process proposal is recorded as considered and declined. Key finding: a disabled service is NOT fully off today - the web server still routes to it and the CGI still spawns, reads the conf and only then refuses (404), and the refusal contract is inconsistent (token-exchange answers 200 {ok:0,code:service_disabled} where the others 404). Recommends generalising the content-history health verdict vocabulary, which already proves the model. Explicitly does NOT propose a process supervisor - systemd keeps that job."
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


# The contract, built 2026-09-05 - exemplar-first

`Lazysite::Lifecycle` defines the common shape and the daemon is its FIRST
CONFORMING CONSUMER. The existing services - WebDAV, control API, MCP, OAuth,
token exchange - migrate afterwards, one per SM, exactly as the plugins did
under ADR 0009. A contract extracted from one real consumer beats one designed
in the abstract and retrofitted five times.

The daemon was chosen because its lifecycle is the least ambiguous in the
system: it is a process, so "running" is a fact rather than an interpretation.
It was also the unit already carrying a recorded debt to this filing - SM666
implemented desired-versus-runtime locally on the understanding that it moved
here when this landed. **That debt is paid.**

## What the verdicts are, and where they came from

`off` `starting` `on` `degraded` `inconsistent` `failed`

**Not a new vocabulary.** `Lazysite::Git::health` has derived `verdict` and
`healthy` over exactly this problem since content-history shipped, and this
filing's own text says that model is what proves the design. Generalising it was
the honest move; a second vocabulary beside it would have been the sixth place a
reader learns one distinction.

**The verdict is derived in ONE place**, from what the caller knows - desired,
running - rather than by each unit deciding for itself. That is the property
worth protecting: a shared word meaning different things per surface is worse
than no shared word.

**A caller may assert a verdict it knows better than the derivation can.** A
unit that tried to start and could not knows `failed`; nothing about
desired-versus-running distinguishes that from never having tried.

## Two decisions inside the shape

**Off-because-you-turned-it-off is HEALTHY**, and carries no remedy. Reporting a
deliberate off as a problem trains an operator to ignore the panel, which is how
a real failure goes unnoticed.

**A remedy is required whenever the verdict is not healthy.** That is not
defensive: SM712, SM730, SM749 and SM750 are four filings in one week about
messages naming a state without naming an action. A status that says
`inconsistent` and stops is the same defect in a different surface - and the
daemon's own case proves the point, because the field met exactly that state and
had to ask what to do next. It now answers with the command.

## What is NOT built, and why

**L2 routing - open decision 1, the substantive call - is untouched.** Whether
to accept a web-server reload coupling and design a privileged helper, or keep
"fully off" at L1 plus discovery suppression, remains the operator's. It does
not bind the exemplar: the daemon has no routed endpoint in phase 1, so nothing
here forces the answer.

**The existing services are not migrated.** SM726 and SM728 both record what a
wide simultaneous UI conversion costs; this follows the same rule, one unit per
SM, each with the tests its own surface needs.

**Open decisions 2, 3 and 4 are deferred** - the refusal contract, plugin
`stop` semantics, and whether `status` needs its own capability. None binds a
single consumer, and each is better answered with a second one in hand.
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

# L0: THE WORK ITSELF, which the three layers above do not cover

Added 2026-09-10, from the release manager's request that "the current embedded
engine switches be made more independent so they are truly off when disabled",
and absorbing SM818, which was filed against this before its author checked for
prior art. SM818's evidence is kept; SM818 itself is superseded.

**L1, L2 and L3 are all about an ENDPOINT.** Refuse the request, do not route to
it, do not install it. That is the right frame for WebDAV, the control API, MCP,
OAuth and token exchange, because each is something a request arrives at.

**Several of the embedded plugins have no endpoint.** Their work happens during
an ordinary page render, inside the core renderer, and no amount of not-routing
touches it. The clearest case is the one the release manager named:

- **The first-party access log has no switch at all.** `lazysite-processor.pl`
  carries "SM140: first-party access log" and builds `%ACCESS_REC` per request.
  There is no `access_log:` key in any conf and no `if enabled` in the write
  path. So disabling `log` or `stats` changes what can be READ, and the engine
  goes on recording every visit. An operator running locally who switches the
  visitor log off still accumulates visitor data.

And the enablement flag is honoured unevenly, because the current mechanism asks
every call site to remember. `plugin_enabled` is consulted at fourteen sites in
nine files:

| Consults it | Does not |
| --- | --- |
| `lazysite-data.pl`, `Manager/Data.pm`, `plugins/form-handler.pl` | `Lazysite::Audit::audit_log` - returns early only on an undefined `$LAZYSITE_DIR` |
| `Manager/Briefs.pm` | the content-history write path |
| `Daemon/Supervisor.pm` | `lazysite-mcp.pl::_stats_export` - locates `plugins/stats.pl` and runs it, erroring only if the file is absent |
| `Lazysite::Notify` (2) | the access log, which has nothing to consult |
| `Manager/StartPage.pm` (3), `Manager/Common.pm`, `Manager/Plugins.pm` (3) - surface and listing | |

Fourteen sites remembered and several did not, which is [[SM666]]'s failure and
SEC-2026-07 (F3)'s: a flag that reaches one reader and not another. So the fix
is not fourteen more checks.

## L0, proposed

**Core calls through a registry, and a disabled unit is not in it.** Where the
renderer wants a visit recorded it calls a recorder the `log` unit registers;
with the unit off there is no recorder and no call. Truly-off then holds by
construction, and a fifteenth call site added next year inherits it.

Two consequences worth stating:

1. **The access-log write moves out of the core renderer.** Under the principle
   the release manager set for [[SM817]] - the core renders, standalone and
   simply - recording who visited is a unit's job and is currently core's.
2. **A lint that the registry is the only route.** A direct call from core into a
   unit's file - the `_stats_export` shape - fails, because that is exactly how
   truly-off gets quietly lost again.

Each member then wants a test asserting **no output** when disabled. "The action
refuses" is already true and is what made this invisible.

## The audit trail: RULED 2026-09-10

The question was whether an audit trail should honour its own switch at all,
since one an operator can silence is arguably not an audit trail. **The release
manager has ruled that it stays switchable, and the switch is answerable:**

- The disable and the re-enable are both **written to the trail, with the actor**
  - so the hole has named edges rather than being a silent gap. The disable is
  recorded BEFORE the trail stops, and the re-enable on resumption.
- **A separate group governs the act.** Turning the audit trail off is not the
  same authority as configuring a site, and it should not travel with
  `manage_config`. This is the class of authority [[SM579]] settled for connector
  destinations: a narrow grant for a narrow act.

That is stronger than the "make it core and unswitchable" recommendation it
replaces, and the reason is worth keeping: unswitchable would have removed the
operator's ability to run an instance that records nothing, which is a legitimate
thing to want and is the same requirement the visitor log raises. A recorded,
attributable, separately-granted switch keeps both.

The same treatment is owed to content history, less sharply: a site that turns it
off and then finds a page's past is gone has lost something the switch implied it
was only hiding.

# RULED 2026-09-10: no queue, and the init wants more design

**L2's privileged-helper queue is refused.** The release manager: "not queue
request, these can be confusing." That is the right instinct and it is the same
one this filing is built on - a toggle that appears to take effect and actually
enqueues a privileged action is a second thing that says it did something it has
not done yet, which is the defect L2 exists to fix, reintroduced by the fix.

So if L2 is built, it is built as **"takes effect on next regeneration"**, said
plainly at the point of toggling. No new privileged path, and the operator is
told when the change applies rather than left to infer it.

**And the init needs more design before any of it is built.** Recorded as the
release manager's judgement rather than argued with, and the reasons visible from
here support it:

- The **contract exists and has one conformant consumer** - `Lazysite::Lifecycle`
  and the daemon. Five services (WebDAV, control API, MCP, OAuth, token exchange)
  were to migrate one per SM and none has.
- **L0 arrived after the design was written** and changes its shape: the three
  layers are all about an endpoint, and the embedded units have none. A design
  that names L1/L2/L3 and then discovers L0 is a design that has not finished
  finding its layers.
- **The semantics of OFF were only settled today** (see [[SM798]]): off stops
  collection and does not remove what was collected. The lifecycle verbs have to
  mean that, and `stop` reading as `purge` for one unit and `pause` for another
  is exactly the inconsistency this filing was written about.
- **Enablement now carries constraints** - a separate grant for the audit trail,
  and whatever the rate limiter needs - so `start`/`stop` are no longer a single
  authority.

**What that means practically:** the batch builds L0 and the rename, and the
service lifecycle migration waits for a design pass that has L0, the OFF
semantics and constrained enablement in it from the start rather than bolted on.
Not scheduled here.
