---
title: "SM654: the `unlocks` map is neither an upper nor a lower bound on what a capability reaches, because it is hand-kept beside the code it describes"
subtitle: "Site agent, 2026-08-26: three inaccuracies, in three different fields, in one afternoon - a map understating by 27 tools, a map omitting an admitted tool, and a title asserting the opposite of its own map"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL - the two measured errors are fixed and the MCP half is now linted; generating the map, and the control-API half, are NOT done. FIXED: read_nav joins manage_nav's unlocks.mcp (it declares cap => 'manage_nav', the gate admits it, it returns the nav, and the map said set_nav only); and manage_briefs' TITLE said deleting a brief needs manage_briefs when brief-delete is gated on `purge` - the map beside it was already correct, so the title contradicted its own data. BUILT: t/lint/90 compares every MCP tool's declared cap/cap_also against that capability's unlocks.mcp, both directions - a tool the gate admits and the map omits, and a tool the map names that does not exist. THE FIRST CUT OF THAT LINT PASSED WHILE read_nav WAS STILL MISSING, because it skipped path_aware tools: _tool_callable admits a tool on its DECLARED cap whatever path_aware does, so the path rule is an additional way in, not a replacement, and the exclusion was simply wrong. Caught by sabotage, not by reading. NOT DONE, and both are recorded rather than forgotten: (1) GENERATING the map from %TOOLS and %need - the MCP half is now pinned by the lint, but %need holds PREDICATES (sub { $_[0]->{manage_content} }) so the control-API half cannot be extracted without restructuring a security-critical gate table, which is not a lint's business to force. (2) The manage_themes/manage_layouts rows, which reach tools through the path rule - the listing has no vocabulary for \"callable on some paths\" until SM653 gives it one, and a lint cannot encode a rule the product cannot express. A FOURTH THING FOUND AND DELIBERATELY NOT ACTED ON: several path_aware tools appear to accept no path at all, which would make the flag meaningless on them and is the sharpest form of SM653 - but distinguishing \"takes a path under another name\" (move_file takes from/to) from \"takes none\" needs more than the regex available here, and path_aware is security-relevant. Recorded on SM653 rather than guessed at."
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
