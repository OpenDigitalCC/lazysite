---
id: SM879
title: "SM879: the group card shows what the group actually grants"
subtitle: "Since SM631 split groups into bundles, channels and roles, a role holds nothing of its own - so the capability grid rendered nine of the ten shipped roles as entirely unticked while they granted between three and eleven capabilities. site-admins showed an empty grid and granted eleven. The grid now draws inherited grants too, ticked but not editable, each naming the bundle it comes from."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-14 on claude/sm879-group-card-shows-inherited-capabilities, for 0.14.1. Reported by the release manager on agent-ai: 'it doesn't indicate the capabilities or groups that this belongs to... i am looking at ai-agent and can't understand what this group grants.' Measured across the shipped seed before fixing: every role except lead-readers showed an empty grid, and members was the only honest one (grants nothing). _group_settings_view now returns `inherited` ({capability: [source groups]}), derived server-side (SM286) by closing the group graph with the SAME walk authorisation uses - _group_closure split into _group_closure_in so the view can close every group without re-reading the unmemoised groups file once per group. The page draws an inherited grant as a ticked DISABLED box naming its source: a live checkbox would claim the group grants it and invite an unticking that writes a direct deny which does not revoke the inherited grant. A capability held BOTH ways keeps its editable control and is marked 'also inherited'. The summary count, the dormant-service and dormant-plugin flags, and the SM198 inert warning all now read the effective set - each was direct-only and therefore silent on exactly the roles this affects. t/unit/manager/121 RUNS the row builder for the inherited and both cases; t/unit/users/46 pins the server's attribution including a bundle nested two levels up, which is the case a one-level parent scan gets wrong silently."
---

# What the release manager saw

> on groups page, when i look at a group, it doesn't indicate the capabilities
> or groups that this belongs to, so now we have groups of groups, the group
> page really should have the capability grid as well. i am looking at ai-agent
> and can't understand what this group grants.

## What was measured

Read out of the shipped seed and nesting map, before any fix:

| role | the grid showed | a member actually held |
|---|---|---|
| `agent-ai` | nothing | 9 |
| `site-admins` | nothing | 11 |
| `mcp-ai` | nothing | 7 |
| `app-developers` | nothing | 6 |
| `content-editors` | nothing | 5 |
| `user-managers` | nothing | 5 |
| `design-team` | nothing | 4 |
| `analysts` | nothing | 3 |
| `members` | nothing | 0 (honest) |
| `lead-readers` | some | 3 |

`agent-ai` grants `manage_content`, `manage_forms`, `manage_nav`,
`manage_themes`, `manage_layouts`, `analytics`, `mcp`, `api` and `webdav`,
every one of them through nesting, none of them drawn.

## Why it was invisible for so long

The page knew. `groupParents()` already computed the bundles a group rolls up
into, and the summary line showed **"in 5 bundles"** with the names in a
tooltip. The section note under Roles even states the trap in as many words:
*"which is why a role can look empty and still grant a great deal."*

So the fact was present as a **count**, and absent as an **answer**. Somebody
had already noticed the shape and fixed the cheaper half of it.

## The judgement calls

**Disabled, not ticked.** An inherited grant renders as a ticked box that
cannot be clicked. A live one would be wrong twice over: it would say this
group grants the capability, and unticking it would write a direct *deny* of
something the group never held directly — which does not revoke the inherited
grant. The operator would watch the box spring back and conclude the page was
broken. The control has to be unusable because the action it implies does not
exist here.

**Derived on the server, by the same walk.** The page could have scanned
`allGroups` for groups listing this one as a member. That answer is wrong the
moment a bundle sits inside another bundle: it stops at one level and
under-reports *silently*. `_group_closure` is the one place the group graph is
walked for authorisation, and the view now asks it, so what the page shows and
what the engine enforces cannot disagree.

**The flags that were already there were also direct-only.** The dormant-service
warning (SM180), the dormant-plugin warning (SM675) and the inert-group warning
(SM198) all asked `caps[...]`. A role inheriting `mcp` with the MCP service off
is exactly as dormant as one holding it directly — and under the old test those
warnings could never fire for most roles, which are precisely the groups an
operator administers.

## Related

[[SM631]] introduced the three layers this failed to render. [[SM198]] and
[[SM576]] added the summary-line signals that pointed at the gap without
closing it.
