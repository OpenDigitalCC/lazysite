---
title: "SM350 - The control API publishes no action reference"
subtitle: "MCP has `tools/list` with a schema per tool. The control API - an enforced, first-class channel - has no equivalent and no documentation page. Across 23 reference docs and 7 briefings, a search for its action names returns one incidental mention."
brand: plain
status: candidate
---

# SM350 - a first-class channel nobody can enumerate

## What was measured

edge 0.10.12. `describe-capabilities` declares four channels, each
`enforced: true`:

```
api     "The token-authenticated control API (structured actions)."
mcp     "The MCP connector (Claude.ai / ChatGPT / Code tools)."
ui      "Interactive manager UI over a browser cookie session."
webdav  "The /dav publishing endpoint ..."
```

Discovery available per channel:

```datatable
columns: Channel | How a caller learns what it can do
widths: 3.4cm | X
bold: 1
tone: medium
---
mcp | `tools/list` - 51 tools, each with a full JSON Schema, required fields and parameter descriptions
webdav | Standard verbs, plus `/docs/authoring` and the publishing briefing
ui | The manager walkthrough in `docs/manager-ui-guide/`, lint-enforced
api | **Nothing**
```

The documentation index lists 23 reference pages and 7 AI briefings.
`/docs/api` documents front-matter `raw:` and `api:` mode for *pages* -
a different feature that shares the word. `/docs/ai-connector-tools`
documents the MCP tools. Grepping all three likeliest documents for
control-API action names returns a single incidental `domain-add`.

## How a caller discovers an action today

Three ways, none of them a reference:

1. `describe-capabilities` names some actions inside `tasks` prose -
   `theme-activate`, `layout-install`, `git-history`, `site-backup-create`
   and a few others. It is a task guide, not an index, and it lists only
   the actions those eight tasks happen to use.
2. Guessing, against the refusal message. That message is good - it names
   the doubled-`action=` cause and points at `describe-capabilities` -
   but it is still a guessing loop.
3. Reading someone else's code.

## Why it matters

**The API is the channel without an agent holding its hand.** MCP callers
get schemas injected into their context automatically. A script, a cron
job or an operator's own tooling uses the control API, and that caller has
the least support and the fewest affordances.

**Parameter shape is undiscoverable, and this has already cost a live
incident.** The runbook for this instance records `acl-set` taking its
path from the query string while the JSON body silently discarded a
`path` key - which took a whole site private for about a minute.
[[SM306]] fixed the refusal. Nothing yet tells a caller, in advance, which
parameters an action reads and from where.

**It undercuts the parity work.** This pass found the API and MCP agreeing
almost everywhere - `acl-get` / `get_permissions`, `layouts-manifest` /
`list_layout_catalogue`, `git-history` / `list_versions` all return
equivalent payloads. That parity is invisible to anyone who cannot see
the API half.

## The fix

An `actions-list` action, mirroring `tools/list`: every action the calling
account may use, with its parameters, where each is read from (query
string or body), which are required, and the capability it needs.

It should be generated from the dispatch table rather than hand-written.
The register already records three defects caused by hand-maintained
lists - `t/lint/31` templates, `t/lint/39` scripts, `t/lint/41` packaging
- and a hand-written action reference would be the fourth.

Given that, the docs page can be generated from the same source, so the
published reference cannot drift from the dispatcher.

## Verification

- `action=actions-list` returns every dispatchable action for the calling
  account, with parameters and required capability.
- An action added to the dispatcher appears without a second edit.
- Each entry states whether a parameter is read from the query string or
  the request body.
- An account lacking a capability does not see the actions it cannot call,
  matching how `tools/list` already subsets for an unidentified caller
  ([[SM210]]).
- A published reference page is generated from the same source.

## Related

[[SM210]] (tools/list subsetting - the precedent for what a caller may
enumerate), [[SM306]] (the `acl-set` path refusal, the incident this would
have prevented), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
