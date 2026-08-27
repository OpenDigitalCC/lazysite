---
title: "SM589: a zero-capability principal still sees which plugins are installed, enabled, and where their scripts live"
subtitle: "SM565 gated the schemas, the group names and the theme list. What remains is an inventory - twelve plugins with their enablement state and script paths, and eight layout names."
brand: plain
standard-margins: true
status: shipped
status-note: "DECIDED BY THE OPERATOR 2026-08-25: WITHHOLD BOTH, the filing's own recommendation. SHIPPED 0.10.33 in the control API's whoami, which is the ONLY surface that emits the inventory - MCP's whoami and describe_capabilities do not, so this is a one-surface fix rather than a twin. `_script` AND `config_file` are withheld from every caller: both are internal filesystem paths, and the Plugin Manager reads them from `plugin-list`, which is gated separately, so no UI loses them. `_enabled` is shown to a caller holding manage_config, OR any capability the plugin declares it owns - a manage_briefs holder learning the briefs plugin is off is being told about its own capability, not about the site's shape. id, name, description and version stay discoverable, so a partner still learns which features exist. Proven in t/unit/manager/10: four assertions at the floor, one for manage_config, and two for the capability-holder branch - the last sabotage-verified, since gating on manage_config alone still passes every other assertion. MEASURED BY THE SITE AGENT 2026-08-25 on 0.10.32 at the capability floor (api/mcp/webdav, no capabilities): manager_groups, themes and every plugin config_schema are now withheld - the sensitive half of SM565, done. Still returned: 12 plugin entries carrying id, name, description, version, _enabled, _script, config_file; and 8 layout names with active_layout and active_theme. The agent explicitly declines to call the inventory itself a finding, on the ground that a partner arguably needs to know which features a site has before it can use them, and names two fields it questions instead: _enabled (what is switched on) and _script (where the code lives). Neither is needed to USE a feature; both describe the installation to a caller holding nothing. DECISION FOR THE OPERATOR: was the inventory the intended stopping point, or should _enabled and _script join the schemas behind a capability? RECOMMENDATION: withhold _script unconditionally (an internal path is never a partner's business) and gate _enabled on any capability the plugin itself governs, leaving id/name/description/version as the discoverable surface. PLANNED for 0.10.33 with the rest of the SM565 family."
---

# What the floor sees now, and what it saw before

| | 0.10.31 | 0.10.32 |
|---|---|---|
| manager group names | all six | withheld |
| plugin config schemas | keys, labels, defaults, notes | withheld |
| theme list | all, incl. backups | withheld |
| plugin inventory | 12 entries | **12 entries, incl. `_enabled` and `_script`** |
| layout names | 8 | **8, plus active layout/theme** |

# Proving test

`t/unit/manager/10`: `whoami` for a token holding no capability returns
no `_script` for any plugin, and no `_enabled` for a plugin whose
governing capability the caller lacks.
