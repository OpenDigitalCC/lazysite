---
title: "SM565: whoami tells a zero-capability principal the shape of the site"
subtitle: "At the capability floor, whoami disclosed every manager group name, every plugin with its config schema, and every theme including backups."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): action_whoami returns manager_groups only to manage_users, the theme inventory only to manage_themes/manage_layouts, and strips config_schema/config_keys from the plugin list unless the caller holds manage_config; the caller's own capabilities, reachability, groups and scope denies are unchanged. t/unit/manager/10 pins the floor and each governing capability. OBSERVED BY THE SITE AGENT 2026-08-25 on the floor row (api/mcp/webdav channels, no capabilities): whoami returned manager_groups (agent-ai, content-editors, design-team, lazysite-admins, mcp-ai, user-managers), plugins with config_schema (keys, labels, defaults, notes) and the full theme list. The scope deny list is useful to a caller; group names and plugin configuration schemas are reconnaissance. Not filed by the agent - filed here so the operator decides whether the disclosure is deliberate. PLANNED for 0.10.33 under SM516 if it is not."
---

# The proving test

t/unit/manager/10: whoami for a token holding no capability returns its own caps and scope denies and NOT manager_groups, plugin config schemas or the theme inventory.
