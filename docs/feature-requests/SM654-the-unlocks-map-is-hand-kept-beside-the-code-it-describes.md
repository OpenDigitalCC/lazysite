---
title: "SM654: the `unlocks` map is neither an upper nor a lower bound on what a capability reaches, because it is hand-kept beside the code it describes"
subtitle: "Site agent, 2026-08-26: three inaccuracies, in three different fields, in one afternoon - a map understating by 27 tools, a map omitting an admitted tool, and a title asserting the opposite of its own map"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL, and the blocker is gone. The two measured errors are fixed, the MCP half is linted by t/lint/90, and THE CONTROL-API HALF IS NOW LINTED TOO by t/lint/105. That half was recorded as not-done for one reason - %need held PREDICATES, so the capability could not be extracted without restructuring a security-critical gate table, which is not a lint's business to force. SM662 restructured it, so the answer is data and the lint was written against it. It checks BOTH directions, which fail differently: over-claiming is visible and self-correcting (an operator grants and is refused), while SILENCE is the half nobody notices - the gate admits an action the map omits, so the grant is wider than the page read before making it, which is exactly what SM664 hit. It found one thing on its first run: manage_services claims config-set, and does not gate it - the ACTION is gated on manage_config and manage_services is checked separately against particular KEYS, so holding it alone opens nothing. Recorded as a named exemption with its reason rather than bending the rule. WHAT REMAINS: GENERATING both maps from the declarations rather than checking them, and the manage_themes/manage_layouts rows."
---

# Wrong in both directions

| Capability | `unlocks` (mcp) says | `tools/list` actually offers |
|---|---|---|
| `manage_themes` | 5 tools | **34** - the 27 `path_aware` tools too |
| `manage_layouts` | 4 tools | **33** - same mechanism, symmetric |
| `manage_nav` | `set_nav` only | **`read_nav` too** - and it works |

The first two understate. The third omits. A reader cannot treat the map as a
ceiling ("at most this") or as a floor ("at least this"), which leaves it with
no useful reading at all.

`read_nav` is the cleanest case: it declares `cap => 'manage_nav'` in source,
the gate admits it, it returns the nav, and the map does not mention it. Nothing
is ambiguous about it - the map is simply out of date.

# The third field

`manage_briefs`' title says deletion is included. Deletion needs `purge`. The
map immediately beside the title says so correctly.

That is the same root cause in prose rather than in data, and it is the reason
this is one filing: a capability's title, its `unlocks` map and the tables that
actually gate the tools are three descriptions of one fact, all maintained
separately, and any two of them can disagree without anything noticing.

# Why the structural fix is the only one worth taking

Each individual error is a one-line correction. `read_nav` is one entry. The
title is one sentence.

Three of them appeared in a single afternoon's testing, in three different
fields. That rate is the finding. The map is written by hand beside the code it
documents, so it drifts at whatever rate the code changes, and the only thing
that has been catching the drift is an agent reading both and noticing.

- **Generate `unlocks` from `%TOOLS` and `%need`.** The tables already hold the
  truth; the map is a second copy of it maintained by discipline.
- **A lint** asserting every `%TOOLS` entry's `cap` / `cap_also` appears in that
  capability's `unlocks.mcp`, and that every `unlocks.mcp` entry exists in
  `%TOOLS`. That would have caught the `read_nav` omission outright.

The `path_aware` rows cannot be linted until SM653 gives the listing a way to
say "callable on some paths", which is an argument for taking these two
together.

# The papercut, recorded

A nav refusal names the wrong capability for `lazysite/nav*.conf` paths.
Specific refusal text for those paths is a small, separate fix.
