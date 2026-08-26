---
title: "SM623: five service toggles ordered by when they were added, so the two a web connector needs sat either side of one it does not"
subtitle: "Operator request: one button for 'enable MCP' and one for 'enable agent' that switches the appropriate toggles, to reduce mistakes"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (2026-08-26). The Services group listed WebDAV, MCP, OAuth, control API, token exchange - the order they were built in - so an operator setting up one kind of connection had to already know which of five unrelated-looking switches applied to it. Now grouped BY WHAT A CLIENT NEEDS, using the same split the connector panel checks (SM622): 'Services: web AI connector (Claude.ai, ChatGPT)' = mcp + oauth; 'Services: agent and CLI access (Claude Code, Desktop, scripts)' = control API + WebDAV + pairing-key exchange. token_exchange_enabled was relabelled from 'AI-partner token exchange' to 'Pairing key exchange and token rotation', because what it gates is whether a brief you just issued can be redeemed at all - the old label named the parties, not the consequence. EACH GROUP CARRIES A PRESET that sets exactly its own switches. SETS AND MARKS DIRTY, DOES NOT SAVE: turning a remote surface on is precisely the change that should be looked at once before it reaches a live site, and the operator sees the switches move before pressing Save. THE PRESET SETS ARE WRITTEN OUT rather than derived from the schema, because the schema says which GROUP a toggle is in and the preset says what a WORKING setup is - those are allowed to differ, and 'allowed to differ' is exactly how a toggle joins a group and gets silently left out of its own button. t/unit/manager/124 pins the two to each other and fails if a group member is missing from its preset, if a preset turns anything OFF, or if it saves by itself."
---

# Before and after

| Was | Now |
|---|---|
| WebDAV | **Web AI connector**: MCP, OAuth |
| MCP | **Agent and CLI**: Control API, WebDAV, Pairing key exchange |
| OAuth | |
| Control API | |
| Token exchange | |

The two a web connector needs were separated by one it does not.
