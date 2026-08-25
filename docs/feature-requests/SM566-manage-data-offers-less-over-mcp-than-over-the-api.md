---
title: "SM566: manage_data offers less over MCP than over the API - and the missing piece is the safety step"
subtitle: "The API has 15 data-* actions; MCP has 11 tools. migrate-plan and table-source are absent over MCP, so an agent can migrate a table without previewing what the migration would do."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): plan_data_migration (twin of data-migrate-plan) and read_data_table_source (twin of data-table-source) added under manage_data, mirroring the sibling data tools - cap, inputSchema, %ANNOTATE read-only, Capabilities.pm unlocks, t/lint/23 %PAIR (the %API_ONLY reasons removed), starter/docs/data-tables.md, docs/reference regenerated; proving test in t/unit/mcp/09 (the plan names the blocked price change and applies nothing; the descriptor reads back as text; manage_content is refused). OBSERVED BY THE SITE AGENT 2026-08-25 on the manage_data row: import/export are plausibly deliberate (file-transfer shaped); data-migrate-plan is the SAFETY step before data-migrate and has no MCP twin, so the same operation is more dangerous on one channel; data-table-source has no twin, so an MCP agent cannot read-modify-write a descriptor as text. Both currently recorded as API_ONLY in t/lint/23 with reasons written when the data plugin was new. PLANNED for 0.10.33 under SM516: add plan_data_migration and read_data_table_source, or record the decision to withhold them with the safety consequence stated."
---

# The proving test

t/lint/23's %PAIR gains the two twins; t/unit/mcp/01 drives plan_data_migration against a table whose migration would be refused and asserts the plan names the blocked change.
