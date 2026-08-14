---
title: "SM301 - regenerate_registries is reachable over MCP only"
subtitle: "An account holds manage_content and cannot call the action that manage_content grants, because its grant is WebDAV plus the control API. The capability is not the obstacle; the channel is."
brand: plain
status: candidate
status-note: "FILED 2026-08-14 from a site-agent report. SM251 shipped regenerate_registries in the 0.10.4 edge line and exposed it on MCP alone. The parity lint did NOT miss this - t/lint/23 records it as a DELIBERATE MCP-only entry whose stated condition is 'the API path can add one when someone asks for it'. Someone has now asked, from a live site, with a worked example of the damage caused by not having it. This filing is that trigger firing, not a defect report."
---

# SM301 - the capability is held and the door is shut

## What was found

`regenerate_registries` appears in `Capabilities.pm:67` under `manage_content`,
in the `mcp` list. `grep regenerate-registries lazysite-manager-api.pl` returns
nothing.

The reporting account's grant is WebDAV plus the control API with `mcp: false`,
and its partner brief says explicitly not to use an auto-detected MCP connector
for that account. So the account holds `manage_content`, needs the action that
`manage_content` grants, and cannot reach it. Its remaining lever is to save a
page and request it, which works by side effect.

## Why it matters beyond the inconvenience

The report's own account of the incident is the argument. Having no supported
way to refresh a registry, the agent deleted the generated file - and
established, after three rounds of getting it wrong, that **deleting a registry
is not a cache invalidation but an outage that ordinary traffic will not clear**:

> a registry is rebuilt during page processing, when its output is missing or
> older than `$REGISTRY_TTL`. Requesting `sitemap.xml` does not run the
> processor, and a cached page request is not a render.

On a stable site with a warm cache and no editing, nothing runs the processor,
so a deleted registry can stay 404 indefinitely. The reporter took `sitemap.xml`
down for about a minute and `llms.txt` for longer.

The supported action removes the reason to touch the file at all - for accounts
that can reach it.

## The lint already knew, and said so

This was NOT a silent gap, and the correction is worth recording because the
first draft of this filing assumed it was.

`t/lint/23-mcp-api-action-parity.t:152` carries the entry:

```perl
'regenerate_registries' => 'deliberate (SM264) - the control API has no twin
    yet; the need came from an MCP agent verifying a delete, and the API path
    can add one when someone asks for it',
```

So the asymmetry was assessed, recorded with its reasoning, and given an
explicit condition for revisiting it. That is the lint working as designed: it
requires every one-sided action to carry a *recorded reason*, and distinguishes
`deliberate` from `undecided` (there are 29 of the latter).

**The condition has now been met.** Someone has asked, from a live site, with a
worked example of what the absence costs. This filing is that trigger firing.

## The fix

Add `regenerate-registries` to the control-API action list, gated by
`manage_content`, so the action follows the capability rather than the
transport, and move the `t/lint/23` entry from `%MCP_ONLY` to the paired map.

## Also worth a line in the briefing

Independent of the fix: deleting a generated registry file fails quietly and is
the obvious wrong move. The publishing briefing should say so.

## Related

[[SM251]] (which shipped the action), [[SM288]] (the same parity shape),
`t/lint/23`.
