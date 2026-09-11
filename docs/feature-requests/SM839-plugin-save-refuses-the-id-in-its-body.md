---
title: "SM839: plugin-save refuses a listing id in its body, and tells the caller to pass the id"
subtitle: "Sites agent, 1312E-05, 2026-09-11: SM832 closed the id gap on the plugin parameter and left it open on the body's script key - the one route its own missing-argument error advertises"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11. The confirmed id lookup SM832 added now runs for whichever name the caller supplied, the plugin parameter or plugin-save's body script key, so all four routes the field tried for link-audit resolve. t/unit/manager/170 gained the body route for both extensions whose id is not their filename; against the old resolver both fail."
---

# What was measured

Four ways to name `link-audit` (id `link-audit`, script `plugins/audit.pl`):

| How it was named | Result |
| --- | --- |
| `?plugin=link-audit` - query, id | OK |
| `?plugin=plugins/audit.pl` - query, script | OK |
| body `{"script": "plugins/audit.pl"}` - script | OK |
| body `{"script": "link-audit"}` - **id** | **REFUSED** |

The refusal - *"no plugin 'link-audit' is installed - call plugin-list and pass a
plugin's `id` or its `_script`"* - tells the caller to pass the id on the one
route that will not take it. The missing-argument error for the same action
names that route: *"in the JSON body as {"script": "<id>"}"*.

# Why

Confirmed in the source: `_resolve_plugin_or_why` resolves a declared id only for
`$plugin_id` (`Plugins.pm`, the SM832 block). `$script` is tried as a registry
key and nothing else. It was invisible for every extension whose id is its
filename, which is twelve of fourteen; `link-audit` is one of the two that is
not, which is how the field found it.

# The shape

Run the same confirmed id lookup for whichever of the two was supplied. Pinned by
extending `t/unit/manager/170` to all four routes for both exceptions.

# Related

[[SM832]] (the fix this completes).
