---
title: "Agent capability discovery and onboarding"
subtitle: "A machine-parseable capability map, quickstarts, and a legible private-file boundary"
brand: plain
standard-margins: true
---

## Why this document exists

A connecting partner - increasingly an AI agent rather than a person - has no
reliable way to learn what it is allowed to do or how to do it. One agent spent
a long time discovering by trial and error that themes install over WebDAV,
because the push failed without saying why. That specific failure (RI-002) is
now fixed: a refused WebDAV write names its reason in the body and an
`X-Lazysite-Deny-Reason` header. But that only tells an agent why one request
failed after it has already guessed wrong. It does not tell the agent, up front,
the shape of what it may do.

This document scopes the four connected asks recorded in the backlog under
"partner-agent onboarding & capability discoverability", ordered by leverage:

- a **capability map** an agent fetches once and traverses (the headline);
- **theme and layout quickstarts** that put an agent on the sanctioned path fast;
- a **legible private-file boundary** so an agent does not edit the engine as a
  workaround;
- a **host-OS dependency list** so "what must I install" is a document, not a
  discovery exercise.

::: widebox
The engine already knows the whole permission model - it is enforced on every
request. The gap is that the model is never *published*. This is largely an
exposure problem, not a new-mechanism problem: derive one machine-readable map
from the sources of truth that already exist, and surface it where an agent
looks first.
:::

## What exists today

The permission model is settled (SM095, ADR 0003) and enforced, but it is
described only in prose and enforced by code an agent cannot read. A capability
is a **channel** (where) crossed with an **action** (what), both drawn from one
authoritative list, `@CAP_KEYS` in `lib/Lazysite/Auth/Settings.pm`. Capabilities
are carried by groups; an account's rights are the union across its groups.

```datatable
columns: Concept | Source of truth | Exposed to an agent today?
widths: 4.2cm | X | 4.2cm
bold: 1
tone: medium
text: 2
---
The capability list (15 keys) | `@CAP_KEYS` (`Settings.pm:21`) | No - only prose in FEATURES.md
Channels (ui/webdav/api/mcp) | `@CAP_KEYS` + entry-point script | Partially - names only
Control-API action to capability | `%need` (`lazysite-manager-api.pl:277`) | No structured form
MCP tool to capability | `%TOOLS[*]{cap}` (`lazysite-mcp.pl:237`) | Tool *names* via `tools/list`; not the cap
WebDAV path to capability | imperative `authorise`/`authorise_layout` | Only reactively, via a 403 reason (RI-002)
The caller's own grant | `caps_for($user)` | Yes - `whoami` (both API and MCP)
```

The caller's own grant is already introspectable: `whoami` exists as both a
control-API action (`action_whoami`, `lazysite-manager-api.pl:1139`) and an MCP
tool (`lazysite-mcp.pl:238`). The MCP form is the closest thing to a map - it
returns the full `caps_for` hash plus the tool-name list. What no endpoint
returns is the **static model**: which capability unlocks which surface, and
what the sanctioned sequence for a task (install a theme) actually is.

### Ground-truth findings to address alongside the feature

The survey of the model surfaced three pre-existing issues that this work should
fold in rather than paper over:

Drift in the hand-maintained copies
: the control-API `whoami` capability block hand-lists 14 caps and omits
  `delegate_sub_user_creation` (`lazysite-manager-api.pl:1159`); the manager grid
  hard-codes its `channels`/`actions` arrays (`tools/lazysite-users.pl:2132`)
  instead of deriving them from `@CAP_KEYS`. Any new map must derive from
  `@CAP_KEYS` and these existing duplicates should be re-pointed at it.

The `api` and `mcp` channel caps are modelled but not gated at the transport
: `ui` and `webdav` are enforced as channel gates, but the token (`api`) path and
  the MCP server dispatch on the per-action capability only - they do not check
  `caps_for($user)->{api}` / `->{mcp}` before dispatch. A capability map must not
  advertise a guarantee the engine does not make: either gate the channel at the
  transport, or describe these two as "action-gated only". This needs a decision
  (see Open questions).

No structured WebDAV path to capability table exists
: the DAV rules are imperative logic. The map will need that table encoded as
  data (the RI-002 work already enumerated it in the denial reasons).

## Proposal

### 1. A capability map endpoint (the headline)

One introspection call, returning both the **static model** (what is possible and
what each capability unlocks) and the **caller's grant** (what this account
holds, and therefore what it can do right now). Derived entirely from the
existing sources of truth so it cannot drift.

Expose it in three places, all backed by one builder:

- an MCP tool `describe_capabilities` (the primary surface - agents live here);
- a control-API action `describe-capabilities` (parity for token clients);
- a static, unauthenticated `docs/reference/capability-map.md` generated from the
  same builder, so a human or an agent without a session can read the model
  (the grant half is omitted in the static form).

A single builder (say `Lazysite::Capabilities::describe`) walks `@CAP_KEYS`,
`%need`, `%TOOLS`, and an encoded DAV path table, and returns a structure of this
shape:

```json
{
  "channels": {
    "ui":     { "enforced": true,  "note": "interactive cookie session" },
    "webdav": { "enforced": true,  "note": "/dav publishing endpoint" },
    "api":    { "enforced": false, "note": "action-gated only (see caveat)" },
    "mcp":    { "enforced": false, "note": "action-gated only (see caveat)" }
  },
  "capabilities": {
    "manage_themes": {
      "title": "Install and activate themes",
      "unlocks": {
        "mcp":    ["list_themes", "activate_theme"],
        "api":    ["theme-activate", "theme-list"],
        "webdav": ["write under lazysite/layouts/<layout>/themes/<theme>/"]
      },
      "notes": ["the active theme is read-only over WebDAV"]
    }
  },
  "tasks": [
    {
      "id": "install-theme",
      "title": "Install a theme",
      "requires": ["manage_themes"],
      "steps": [
        "PUT theme files under lazysite/layouts/<layout>/themes/<name>/ over WebDAV",
        "or call the MCP tool activate_theme once the files are in place"
      ]
    }
  ],
  "engine_owned": [
    "lazysite/auth/**", "lazysite/cache/**", "lazysite/forms/*.conf (secrets)",
    "cgi-bin/**", "*.pl"
  ],
  "holds": {
    "account": "partner-x",
    "groups": ["publishers"],
    "capabilities": { "manage_content": true, "manage_themes": false }
  }
}
```

The `tasks` array is where discovery becomes *actionable*: it is the
machine-readable form of the quickstarts (thread 3), so an agent can plan a job
without reading prose. `engine_owned` is the machine-readable form of the
guardrail (thread 3/4). `holds` folds in what `whoami` already returns, so an
agent needs one call, not two - `whoami` can then become a thin alias or be
absorbed.

### 2. Actionable failure messages - mostly delivered

RI-002 already added a named reason and an `X-Lazysite-Deny-Reason` header to
WebDAV denials. Two follow-ons complete the loop:

- carry the same "which capability, and how it is granted" phrasing into the MCP
  `-32002` denial and the control-API refusal, so all three channels speak the
  same language;
- where a denial names a capability, cross-reference the map (`see
  describe_capabilities`) so a refused agent has a next step, not just a reason.

### 3. Theme and layout quickstarts

Short, task-focused guides on the sanctioned path (WebDAV / API / MCP), each a
copy-pasteable sequence rather than prose scattered across FEATURES / SECURITY /
IMPLEMENTOR. Author them once as the human-readable twins of the `tasks` array in
the map, so the two cannot disagree:

- install a theme; switch the active theme;
- author a layout; activate it;
- publish a page; wire a form to a handler.

Home: `docs/reference/quickstarts/` (human) generated alongside the `tasks` block
(machine), from a single source.

### 4. A legible private-file boundary

The engine is already protected - the DAV blocklist and the whole-`lazysite/`
denial (bar the `layouts/` carve-out) mean an agent *cannot* write the processor,
auth files, or cache. The reported problem is legibility, not a hole: an agent
that cannot see the boundary is tempted to look for workarounds.

Two options, not mutually exclusive:

Encode the boundary in the map
: the `engine_owned` array above makes the protected surface explicit and
  machine-readable. Low risk, no migration, and it travels with the capability
  map an agent already fetches. **Recommended as the baseline.**

Adopt an `_`-prefix convention for private files
: prefix engine-owned and author-private files/folders with `_` as a visual "do
  not touch" signal. This reads well, but retrofitting it to the existing tree
  (`lazysite/auth`, `cache`, `manager`) is a breaking rename touching the
  installer, the blocklist, every path constant, and live sites. Scope it, if
  wanted, as a convention for **new** private author files only (e.g. `_drafts/`)
  rather than a rename of the existing engine layout.

### 5. Host-OS dependency list

The data already exists in `dist/config/sbom-deps.json`, and the dev server
already prints Debian package hints when a module is missing. Turn that into a
first-class, agent/operator-readable artefact:

- a generated `docs/reference/host-dependencies.md` (Debian package names, with
  the "why" per dependency) derived from `sbom-deps.json`;
- a `lazysite-check.pl --dependencies` (or a control-API `dependencies` action)
  that reports required-vs-present, so an agent can query the gap directly;
- a pointer from IMPLEMENTOR.md.

## Phasing and effort

```datatable
columns: Phase | Deliverable | Rough effort
widths: 2.2cm | X | 3cm
bold: 1
tone: medium
text: 2
---
A | The capability-map builder + `describe_capabilities` (MCP + control-API), derived from `@CAP_KEYS` / `%need` / `%TOOLS` / an encoded DAV table; re-point the drifting duplicates at it | Medium - the headline, most of the value
B | The `tasks` block + human quickstarts from one source; static `capability-map.md` | Small-medium, builds on A
C | `engine_owned` in the map + documented private-file boundary; decision on the `_` convention for new author files | Small
D | Host-OS dependency artefact + `--dependencies` query | Small, independent of A-C
E | api/mcp transport gating (decided: enforce - folded into A) + unify denial language across channels | Small code, gating now in A
```

Phases A and D are independent and could proceed in parallel; D is the cheapest
standalone win. B and C depend on A's builder. **Current batch: D + A** (with the
E gating decided and folded into A); B, C and the language-unification half of E
follow.

## Decisions (2026-07-02)

- **api/mcp channel gating: gate at the transport (enforce).** The token (`api`)
  path and the MCP server will check `caps_for($user)->{api}` / `->{mcp}` before
  dispatch, matching the `ui`/`webdav` gates, so the capability map can advertise
  all four channels as enforced. This is folded into Phase A (it supersedes the
  Phase E "decision" half). Backward-compat caveat: existing partner accounts
  must actually hold the channel cap, so enforcement ships with a migration step
  (grant the channel cap to accounts that use it) - verified before rollout.
- **Code quality (separate track, parked): adopt `RequireExtendedFormatting`
  (`/x`) project-wide.** The direction is settled - add `/x` across the ~1,200
  patterns, burn down the mechanical remainder, then raise the project Perl::Critic
  gate to severity 3. Not in the Phase D+A batch; scheduled for a quiet window
  (review action 18). Recorded here so the `.perlcriticrc` deviation note is
  updated when that work runs, not before.

## Decisions (continued)

- **Scope of `whoami`: keep both, unchanged (2026-07-03).** `whoami` stays the
  minimal, stable identity + own-grant introspection it has been since SM072
  (existing MCP/control-API clients depend on its shape); `describe_capabilities`
  is the richer map beside it and the recommended first call for a new agent.
  Absorbing or aliasing `whoami` would churn a published contract for no real
  gain - the two answer different questions (who am I / what may I do vs the whole
  model). Revisit only if telemetry shows `whoami` has no remaining callers.

## Open questions

- **Static map exposure.** Should the unauthenticated `capability-map.md` list the
  full model to anonymous visitors? It reveals no secrets (the model is not
  sensitive), but it does advertise the API surface. Likely fine; worth a
  conscious call.
- **Static map exposure.** Should the unauthenticated `capability-map.md` list the
  full model to anonymous visitors? It reveals no secrets (the model is not
  sensitive), but it does advertise the API surface. Likely fine; worth a
  conscious call.
- **The `_`-prefix convention.** Worth adopting for new private author content, or
  is the machine-readable `engine_owned` list enough on its own?
