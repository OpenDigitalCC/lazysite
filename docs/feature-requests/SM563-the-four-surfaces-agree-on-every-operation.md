---
title: "SM563: the four surfaces agree on every operation"
subtitle: "SM570 was two capability tables disagreeing about WHO; the manager cookie map, the token gate, the MCP tool caps and the DAV verb map are four tables and only two pairs are compared."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): NEW t/lint/87-the-four-surfaces-agree-on-every-operation.t compares, per logical operation (read content, write content, set a rule, write a theme file, read submissions), the capability set across %COOKIE_CAP, %need, the MCP tool caps and the capabilities lazysite-dav.pl's authorise names in its own deny strings; deliberate absences carry reasons (lint-23 style, stale exemptions fail) and a channel capability in any column fails on sight. Sabotage-proven in both directions: a webdav flag in the token gate and an MCP cap differing from the API both fail it. ASKED BY THE OPERATOR 2026-08-25 via the site agent while verifying SM570: permissions must align across Manager UI, WebDAV, API and MCP. Today lint 14 pins cookie-vs-token equality, lint 86 pins token-vs-registry, lint 23 (from SM567) pins API-vs-MCP twin capability; the DAV verb map (lazysite-dav.pl authorise) is compared to nothing. PLANNED for 0.10.33 under SM516."
---

# The ask

One lint that, for each LOGICAL operation (read content, write content, set a rule, upload a theme file...), reads the capability set from all four tables and fails on any operation whose four entries do not agree - lint 85 generalised one level up.

# The proving test

The lint itself, seeded with the SM570 shape: a token gate carrying a channel flag, or a DAV verb answering a capability the API refuses for the same operation, must fail it.
