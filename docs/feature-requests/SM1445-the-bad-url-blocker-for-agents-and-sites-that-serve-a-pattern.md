---
id: SM1445
title: "SM1445: the bad-URL blocker, for agents and for a site that serves a built-in pattern"
subtitle: "Three requests from a site owner, held until after stable (ruling 246): an agent adds patterns, an agent sees blocked addresses, and a built-in pattern can be edited or switched off."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-12
raised-by: "a site owner's requests R1, R2 and R4, ruling 246"
area: security
status-note: "OPEN. Target 0.17.x edge, after stable. Features under the freeze (ruling 228): R1 a token or MCP grant adds bad-URL patterns; R2 it sees blocked addresses and a visitor's block state; R4 a built-in pattern can be edited or switched off. No code yet."
---

# What was asked

The owner of a site that was probed asked for four things. R3 (credential-file patterns) is
SM1444. The other three are features and wait until after stable, in 0.17.x edge (ruling 246, 12
Nov 2026, the feature freeze of ruling 228).

# R1: an agent can add bad-URL patterns

A control-API token or an MCP grant can add to the site's extra patterns (`bad_url_extra`) without
the manager UI. Today the key is set on the Extension Config page. To settle when it is built: which
capability gates it, whether a token holds it, and that the write is audited like any
configuration change.

# R2: an agent can see blocked addresses and a visitor's block state

A token or MCP grant can list the blocked addresses and ask whether one address is blocked, and
why (the hits that caused it, or the account that blocked it by hand). Today the list is on the
Extension Config page and in the `bad-url-blocks` control-API action. To settle: the capability,
and that the answer is read-only and names an address only to a caller allowed to see addresses.

# R4: a built-in pattern can be edited or switched off

A site that really serves one of the built-in paths (for example a `/console/` it runs on purpose)
can edit the built-in list or switch one pattern off, instead of exempting every visitor or turning
the blocker off. Today the list is fixed in the engine, and a real file is spared only when it
exists on disk (`site_has_file`). To settle: where the per-site list is kept, that a switched-off
pattern is shown on the Extension Config page and by `lazysite check`, and that a damaged list
refuses rather than counting nothing (ruling 206).

# Not decided

No design, no code, no new setting. This filing records the requests so they are not lost.
