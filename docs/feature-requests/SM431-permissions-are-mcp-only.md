---
title: "SM431: permissions are the one part of manage_content with a single route"
subtitle: "get_permissions and set_permissions exist on MCP and nowhere else - no control-API action, no WebDAV route. A token grant can create gated content it can never inspect, and cannot field-test the rule-follows-content behaviour at all."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 by the field-test account after CF-2 shipped, on discovering it could not verify the change: it can create, move and delete content in a gated namespace but cannot set a rule on it or read one back, so the behaviour is unobservable from that grant in BOTH directions. Their point that it could not have captured a 0.10.18 baseline either is the useful half - nothing was lost by not asking sooner, and that is worth knowing before someone schedules a before/after comparison that cannot be run. NOT A GRANT QUESTION and explicitly not a request for more access: it is a four-surface parity item, and belongs beside SM430's packages. THE ASYMMETRY: manage_content unlocks permissions on MCP and nothing on the control API or WebDAV - so a capability that governs who may read content is reachable through one door out of three, and a holder can produce content governed by a rule it has no way to see. TWO WAYS TO CLOSE IT, and the filing is straight about the trade: control-API get-permissions/set-permissions actions put permissions on the same footing as the rest of manage_content and make the behaviour testable by any token grant, with a real blast radius; an MCP server for edge fixes one account on one host, is the cheap answer, and LEAVES THE GAP IN PLACE. DECISION HELD."
---

# The shape

```datatable
columns: Surface | What manage_content unlocks for permissions
widths: 4cm | X
bold: 1
tone: medium
---
MCP | `get_permissions`, `set_permissions`
Control API | nothing
WebDAV | nothing
```

::: widebox
A capability that governs who may read content is reachable through one
surface out of three. A holder can create gated content and then have no way
to inspect the rule governing it - which is the same class as every other
finding this week, one surface answering a question its siblings cannot.
:::

# Why it surfaced now

CF-2 changed how rules travel with content, and the account best placed to
watch that from outside turns out to be the one account that cannot see rules
at all. The filing is careful to say this is a parity observation rather than
a report of anything failing.

# Related

[[SM430]]'s package set is where this belongs if it is taken as parity work.
It is not one of the fourteen; it is a fifteenth of the same kind.
