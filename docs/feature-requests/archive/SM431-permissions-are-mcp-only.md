---
title: "SM431: permissions are the one part of manage_content with a single route"
subtitle: "get_permissions and set_permissions exist on MCP and nowhere else - no control-API action, no WebDAV route. A token grant can create gated content it can never inspect, and cannot field-test the rule-follows-content behaviour at all."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.29, and the premise needed correcting before the fix made sense: the control API has had acl-get/acl-set/acl-remove since SM074 - the filing's table row 'Control API | nothing' was wrong as an absolute. What was true, and is the real finding, is GATE DIVERGENCE BETWEEN TWINS: MCP's get/set_permissions sat under manage_content while the API's acl actions needed the webdav channel, so the field-test account (manage_content, no webdav) met refusals on one door and working tools on the other - the SM491 shape again, two doors disagreeing about one capability. THE FIX IS PARITY, NOT NEW ACTIONS: the acl actions join manage_content's api unlocks (Capabilities.pm - so describe_capabilities and whoami reachable now say so), the token gate becomes webdav OR manage_content, and t/lint/23's CHANNEL_GATED exemption is REMOVED - the actions now have an action-capability home and the completeness check covers them; the permissions twins are recorded in the pair table. Per-file authorization is untouched: ownership and SM464's read split still decide per rule, this only decides which grants reach the door. WebDAV as a third surface stays out by design - the protocol has no verb for it, and the filing's own framing (four-surface parity) overreached there. t/integration/71 drives the real API: manage_content-only reads and sets on its own content, webdav-only still works, neither-capability is refused with the withheld reason. ORIGINAL NOTE: FILED 2026-08-20 by the field-test account after CF-2 shipped, on discovering it could not verify the change: it can create, move and delete content in a gated namespace but cannot set a rule on it or read one back, so the behaviour is unobservable from that grant in BOTH directions. Their point that it could not have captured a 0.10.18 baseline either is the useful half - nothing was lost by not asking sooner, and that is worth knowing before someone schedules a before/after comparison that cannot be run. NOT A GRANT QUESTION and explicitly not a request for more access: it is a four-surface parity item, and belongs beside SM430's packages. THE ASYMMETRY: manage_content unlocks permissions on MCP and nothing on the control API or WebDAV - so a capability that governs who may read content is reachable through one door out of three, and a holder can produce content governed by a rule it has no way to see. TWO WAYS TO CLOSE IT, and the filing is straight about the trade: control-API get-permissions/set-permissions actions put permissions on the same footing as the rest of manage_content and make the behaviour testable by any token grant, with a real blast radius; an MCP server for edge fixes one account on one host, is the cheap answer, and LEAVES THE GAP IN PLACE. DECISION HELD."
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
