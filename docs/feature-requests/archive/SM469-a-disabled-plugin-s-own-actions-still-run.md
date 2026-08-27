---
title: "SM469: a disabled plugin's own control-API actions still run"
subtitle: "The enabled gate covers plugin SCRIPT execution. A plugin that owns control-API actions - which is what ADR 0009's contract is for - has those actions dispatch straight past it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED (PENDING). THREE PARTS: plugins/data.pl now declares `contract`, which is the opt-in the gate reads - _gate_execution's own comment names the data plugin as the first contract plugin, so the omission was mine rather than a design question; the six actions consult plugin_enabled and refuse with the house shape; and t/lint/77 asserts the property for whatever owns a capability NEXT, which is the durable half. READS ARE GATED TOO - a read is execution, it opens the store and runs a query, and 'disabled but still answering' is the state SM409 exists to remove. CONSEQUENCE WORTH KNOWING: a contract plugin is born DISABLED, so the data plugin must be enabled on the Plugin Manager page before any data action answers. The edge test brief is updated. ORIGINAL FILING FOLLOWS. FILED 2026-08-21, found while writing the edge test brief for the data plugin rather than by a test - which is itself the point, since nothing asserts this. ADR 0009's FIRST clause is 'Off means off. Every dispatch path consults the enabled state: the Manager/Plugins.pm choke point refuses actions on a disabled plugin; a direct-CGI plugin refuses its own requests when disabled; MCP tools backed by a plugin refuse the same way. One rule, stated once: a disabled plugin executes nothing and says so, with the house refusal shape.' SM409 built that gate and it was pulled forward ahead of everything precisely because it is a fix rather than a feature. WHAT IT ACTUALLY COVERS: _gate_execution in Lazysite::Manager::Plugins refuses to RUN A PLUGIN SCRIPT when the plugin is disabled - the `plugin-action` path. The six data actions (data-tables, data-table, data-rows, data-migrate, data-row-save, data-row-delete) dispatch directly into Lazysite::Manager::Data and never consult it, so disabling the data plugin on the Plugin Manager page changes nothing about them. A SECOND, NARROWER GAP in the same function: it returns undef - meaning 'not gated' - unless the plugin's descriptor carries a `contract` key. plugins/data.pl declares `owns` per ADR 0009 and no `contract`, so even the script path would not gate it. Whether `contract` is the right marker or a legacy one is part of the question. WHY IT MATTERS MORE THAN IT LOOKS: the whole point of the ADR's exemplar-first sequencing is that a clause surviving the data plugin is proven rather than speculative. This clause has not survived it - it was simply not applied, and no lint noticed, because nothing checks that a plugin-owned capability's actions consult the plugin's state. THE FIX HAS TWO HALVES and the second is the durable one: gate the data actions, and add a lint that discovers plugin-owned capabilities (t/lint/76 already does that discovery) and asserts every control-API action gated on such a capability also consults the enabled state. Otherwise the next plugin to own actions reintroduces this silently."
---

# What "off" currently means

```datatable
columns: Path | Disabled plugin
widths: 7cm | X
bold: 1
tone: medium
---
`plugin-action` (running the script) | refused, with the house message
A plugin's own control-API actions | **runs normally**
An MCP tool backed by a plugin | not yet built for this plugin
```

# Why nothing caught it

The enabled gate is asserted where it was built -- on the script path. Nothing
asserts the property the ADR actually states, which is about *every* dispatch
path. A capability owned by a plugin is a new shape: before the data plugin,
no plugin owned control-API actions, so there was no path for the gate to
miss.

That is exactly the kind of thing exemplar-first sequencing is supposed to
surface, and it did -- one step later than it should have, because the check
that would have caught it does not exist.

# The durable half of the fix

Gating the six actions is a few lines. The part worth building is the lint:
`t/lint/76` already discovers which capabilities a plugin owns, so it can also
assert that every control-API action gated on such a capability consults the
owning plugin's enabled state. Without it, the next plugin to own actions
reintroduces this and nothing says so.
