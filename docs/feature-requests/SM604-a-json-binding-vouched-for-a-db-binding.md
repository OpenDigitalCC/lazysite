---
title: "SM604: one json: binding made a page's table rows freeze indefinitely"
subtitle: "A snapshot db: binding recorded nothing, on the reasoning that nothing's mtime proves a row unchanged. Recording nothing is safe only while nothing else is recorded."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED BY THE SITE AGENT 2026-08-26, measured on edge (0.10.33) with a probe rig: a page bound only to a table re-rendered every request and stayed current; adding ONE json: binding froze its table rows at the first render, three writes behind by the end of the test. Order did not matter, and a flush brought it straight to current - so the binding resolved correctly throughout and the fault was purely cache freshness. THE TWO MECHANISMS ARE INDIVIDUALLY SOUND AND DISAGREE WHEN COMBINED. A snapshot db: binding records NO dependency, deliberately: there is nothing whose mtime proves a row unchanged, because the store is written through WAL and a row can change without the file's timestamp moving. A json: binding records the file it read, and SM311 makes a cached page fresh while it post-dates every recorded file. Put both on one page and the SECOND mechanism answers for the WHOLE page - the table is not in the record, cannot be, and is never consulted again. THE REASONING WAS RIGHT ABOUT THE TABLE AND WRONG ABOUT THE PAGE: recording nothing is safe only while nothing else is recorded, and a binding does not control what else its page binds. FIXED by marking every db: binding as unprovable-by-mtime, snapshot included. THIS DOES NOT RESTORE THE CLIFF DP-2 REMOVED - the marker withdraws the mtime proof only, and the ttl branch still serves a snapshot page for its declared ttl, which is what 'snapshot's freshness is the page's ttl' always meant. WHAT THE FIX COST, stated because it is a real consequence: `mode=live` and the snapshot default now behave identically, since the mode's ONLY effect was this flag. The mode is vestigial until it is given a difference that matters - live bypassing the ttl branch is the obvious candidate - or removed. That is a design decision and is not taken here. MY FIRST DIAGNOSIS WAS WRONG and is recorded because it was confident: I read a grep as showing resolve_db never set the flag, and proposed a one-line fix that would have reversed DP-2's deliberate snapshot default and reintroduced a database read per visitor. resolve_db DID set it, conditionally on the mode. Reading the DP-2 test's own comments is what caught it. Proven by t/integration/55, which reproduces the field report in a fixture - rows frozen, then current - and asserts the json: half keeps its SM311 behaviour. Sabotage-verified."
---

# What the field measured

| Page | Bindings | Row changed under it | Served |
|---|---|---|---|
| `db-s10` | `db:` only | 3 successive writes | re-rendered every time |
| `mix-a` | `json:` then `db:` | 3 successive writes | **frozen at the first render** |
| `mix-b` | `db:` then `json:` | 2 successive writes | **frozen at the first render** |

Order does not matter, which is the clue: a `db:`-only page re-renders
because it records **nothing at all**, so the freshness check has no
record to consult - not because anything marked it live. Add any recorded
source and the check suddenly has an answer, and it is the wrong one.

# The rule

A page's freshness may be established by mtime only if **every** source it
read can be proven by mtime. One that cannot must say so, or the others
answer for it.
