---
title: "SM409: a disabled plugin still runs"
subtitle: "The plugins: list drives what the Plugin Manager page displays, not what executes. action_plugin_action runs any registered plugin, direct-CGI plugins carry no plugin-level gate, and the MCP stats tool invokes its plugin unconditionally. Disabled is a label."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-19, to the semantic the release manager set when asked: contract-declaring plugins (ADR 0009) are gated and BORN DISABLED; legacy plugins are untouched until each one's migration SM replicates its current effective state, so nothing in the field changes behaviour. The enabled-list parse moved out of action_plugin_list into _enabled_map - its only consumer was the LISTING, which is exactly how disabled became a display state - and plugin_enabled() is exported for direct-CGI plugins to call at entry (the data plugin is the intended first caller). Execution is gated at action_plugin_action; config read/save stay open on a disabled plugin because an operator must be able to configure before enabling; and hooks are deliberately ungated - on_disable runs right after the conf loses the entry and is the plugin's SANCTIONED last run, its one chance to stop what it started, which a hook gate would have refused (caught during implementation, reason recorded in code). Driven by t/unit/manager/62 with two REAL fixture plugins - one contract, one legacy - whose action writes a witness file, so ran/refused are facts on disk; three sabotages bite: gate removed, gate stops discriminating, predicate dead. ORIGINAL FILING FOLLOWS. FOUND 2026-08-19 while sequencing the data-layer work (SM410), verified against the tree: Manager/Plugins.pm derives _enabled from the plugins: list for display and sort only; action_plugin_action resolves and runs any registered script with no enabled check; form-handler.pl is a directly-reachable CGI whose only switches are per-handler enabled flags inside its own config; lazysite-mcp.pl's _stats_tool invokes plugins/stats.pl whenever the analytics capability admits the caller. So an operator who disables a plugin has changed a listing, not the site - the session's recurring defect class (a control reporting one state while doing another) applied to the plugin system itself. FIX SHAPE, per ADR 0009: one enabled predicate exposed from Manager/Plugins.pm; the plugin-action/read/save choke points refuse a disabled plugin with the house refusal sentence; direct-CGI plugins check the predicate themselves at entry (they already locate the module tree - the form-handler notify path shows the idiom); MCP tools backed by a plugin refuse the same way. Small (S), self-contained, safe during the stable chase, and REQUIRED before SM410: db_enabled: yes must mean something on day one. Sabotage-verify per house method: disable a plugin, drive each dispatch path, assert refusal; re-enable, assert execution."
---

# What is true today

- `lib/Lazysite/Manager/Plugins.pm` reads the `plugins:` list and stamps
  `_enabled` onto each descriptor - consumed by the listing's sort order and by
  the Stats page's client-side check. Nothing server-side reads it again.
- `action_plugin_action` / `action_plugin_read` / `action_plugin_save` resolve
  any registered script and run it.
- `plugins/form-handler.pl` is reachable at `/cgi-bin/form-handler.pl`
  regardless of any list; its `enabled` flags are per-handler, inside its own
  config, and govern delivery targets rather than the plugin.
- `lazysite-mcp.pl` invokes `plugins/stats.pl` for `analyse_visitors` gated on
  the `analytics` capability only.

# Why it matters beyond tidiness

An operator disabling a plugin is making a statement about their site's attack
and behaviour surface. Today that statement is recorded and not enforced -
indistinguishable, from outside, from it being enforced, which is exactly the
shape of defect this project keeps finding elsewhere (SM367's cache clear,
SM377's probe, SM390's opt-out).

# The fix, per ADR 0009

One predicate, three kinds of consumer, one refusal sentence. Enumerated
dispatch points: the three Manager/Plugins.pm choke-point actions; direct-CGI
entry for form-handler (and the data endpoint when SM410 lands, which is why
this ships first); the MCP tools that shell out to a plugin.

Out of scope: the `owns` declaration and backup participation (ADR 0009's
larger contract) - this SM is only the off switch, kept small so it can land in
the current round.
