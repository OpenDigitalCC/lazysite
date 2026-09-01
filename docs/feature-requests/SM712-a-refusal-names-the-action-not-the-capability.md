---
id: SM712
title: A control-API refusal names the action, not the capability it needs
raised: 2026-09-01
raised-by: edge-testing agent (0.11.9 regression round 2)
area: control-api
status: shipped
---

# What happens

A credential lacking a capability is correctly refused, and the refusal says:

> Insufficient capability for data-tables. Call describe-capabilities...

The gate fires correctly and points at a remedy. What it does not say is **which
capability**. A caller has to fetch and read the whole capability description to
learn that `data-tables` wants `manage_data`.

# The fix is to copy the surface that already gets it right

The two surfaces disagree, and only one is wrong:

| Surface | Text |
| --- | --- |
| `lazysite-mcp.pl:3764` | `Insufficient capability for $name (needs $need). ...` |
| `lazysite-manager-api.pl:1132` | `Insufficient capability for $action. Call ...` |

MCP already names it. So the value is available at the refusal point on the
control API too - this is not a case of the information being absent, only of
one of two copies not using it.

**That the two exist separately is the more interesting half.** It is SM662's
subject: one capability described in several places, each maintained by hand.
This is a small instance of the same thing, and worth fixing in the direction of
the refusals agreeing by construction rather than by both being edited.

# Why it is worth doing

The reporter's framing is the right one: a cold agent onboards faster when the
refusal names what it needs. The remedy sentence sends them to
`describe_capabilities`; naming the capability makes that lookup targeted
instead of exploratory, and in most cases unnecessary.
