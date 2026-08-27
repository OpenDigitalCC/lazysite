---
title: "SM654: the `unlocks` map is neither an upper nor a lower bound on what a capability reaches, because it is hand-kept beside the code it describes"
subtitle: "Site agent, 2026-08-26: three inaccuracies, in three different fields, in one afternoon - a map understating by 27 tools, a map omitting an admitted tool, and a title asserting the opposite of its own map"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED FROM AN INBOX BRIEF (archived at inbox/archive/), reported by the site agent 2026-08-26 and extended by them the same day when a third instance appeared. describe-capabilities publishes an `unlocks` map per capability, by channel. It is what the briefing tells an agent to read and what an operator reads before granting. THE FINDING IS NOT ANY SINGLE ENTRY: manage_themes' map says 5 MCP tools and tools/list offers 34; manage_layouts says 4 and offers 33 (confirmed symmetric); manage_nav's map lists set_nav only, while read_nav declares cap => 'manage_nav' in source, is admitted by the gate, and returns the nav. So the map understates in one place and omits in another - it is neither an upper nor a lower bound, which is what makes it unreliable rather than merely wrong. A THIRD INSTANCE IN A DIFFERENT FIELD: manage_briefs' TITLE contradicts the map beside it - deletion needs purge, not manage_briefs, and the tier split is deliberate (SM591). THE STRUCTURAL FIX IS THE POINT: generate the map from %TOOLS and %need rather than maintaining it by hand, plus a lint asserting every %TOOLS entry's cap/cap_also appears in that capability's unlocks.mcp and back. Three errors in three fields in one afternoon says the map is drifting from the tables it describes; fixing them one at a time will not stop the fourth. NOTE: the manage_themes/manage_layouts pair is the path_aware listing question filed as SM653 - that one needs SM653's vocabulary before it can be linted. Related: SM515 (every MCP tool declares its gate) - the credential this row used is the one that would have caught U-3."
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
