---
title: "SM572: the engine describes its own side effects"
subtitle: "The control API already classifies every action as mutating or not (%MUTATING, for CSRF). A systematic caller - a sweep, a rig, a migration, a health check - cannot ask, so it has to remember, and the site agent tripped that twice in one day."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): actions-list rows and a describe-capabilities `actions` block carry mutating: true/false read from %MUTATING and destructive: true for the drop/delete/rebuild family (%DESTRUCTIVE beside %MUTATING); MCP's %ANNOTATE stays the second spelling and t/lint/23 keeps the two equal through its twin map, which surfaced four MCP tools (delete_theme, drop_data_table, rebuild_data_table, delete_data_row) now hinted destructive. t/unit/manager/10 proves both directions on both surfaces. ASKED BY THE SITE AGENT 2026-08-25 after two accidental writes during read-shaped sweeps (data-rebuild on a live table; regenerate-registries clearing five roots) - the sweep calls every action bare, and some ACT rather than REPORT. The classification exists internally: %MUTATING in lazysite-manager-api.pl (POST-forced, CSRF-gated), and MCP tools carry %ANNOTATE hints (readOnly / destructive / openWorld) already published to clients. Expose the same fact on the control API: describe-capabilities and actions-list mark each action mutating: true/false (and destructive where the engine knows - drop, delete, rebuild), derived from %MUTATING so it cannot drift from the CSRF gate. Same move as list_briefs - turn 'remember' into 'ask'. Distinct from SM563 (do the four tables agree about WHO): this is whether the engine tells the truth about WHAT an action does. PLANNED for 0.10.33 under SM516."
---

# The ask

`actions-list` and `describe-capabilities` carry, per action, whether it
mutates - read from `%MUTATING`, never restated - and, where the engine
knows, whether it is destructive. A caller can then skip writers by
declaration rather than by memory.

# The proving test

t/lint/14 already parses `%MUTATING`; a new assertion in t/unit/manager/10
calls `actions-list` and checks every `mutating: true` action is in
`%MUTATING` and every member of `%MUTATING` is marked - both directions,
so the description and the CSRF gate cannot disagree.
