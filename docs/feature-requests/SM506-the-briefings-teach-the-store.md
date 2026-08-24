---
title: "SM506: the briefings teach the store, not the sidecar it replaced"
subtitle: "The documents every connecting agent is told to read still promised that a .brief sidecar 'writes through your normal content scope' - the exact promise SM504 inverts."
brand: plain
standard-margins: true
status: shipped
status-note: "RAISED BY THE SITE AGENT 2026-08-24, time-critical for 0.10.30: ai-briefing-publishing taught the sidecar as standard practice, promised a .brief 'is not a blocked extension' (inverted by SM504 the moment the plugin is enabled - an agent doing exactly what the briefing says gets refused), and described a Files-page flag SM245 removed; ai-briefing-authoring step 6 gave the same instruction; ai-connector-tools claimed listing brief metadata that left with SM245 and sidecar carriage on delete_page/rename_page/move_file that SM507 replaced with store carriage. SHIPPED 0.10.30, THE SAME CUT AS SM504, deliberately: the publishing briefing's brief section rewritten for the store (read_brief/append_brief, brief-read/brief-append, briefs-list/brief-delete, the refusal explained, migration pointer, any-path keys and brief-first authoring documented per the operator's proposal - the costs-nothing first step of its recommended order); authoring step 6 repointed; connector-tools' four claims corrected; the MCP delete_page/rename_page descriptions corrected; and the dead createBrief() removed from the Files panel source - never called since SM245's rework, but a plausible-looking function that does the forbidden thing, sitting in the file a future edit would open."
---

# The finding

The AI briefings are how every connecting agent learns the conventions -
the MCP connector instructs agents to read them before authoring. On a
0.10.29 site with the briefs plugin enabled they still taught the retired
sidecar, and one sentence - "a `.brief` is not a blocked extension, so it
writes through your normal content scope" - was an explicit promise that
SM504 inverts. Ship SM504 with the docs unchanged and an agent that does
exactly what the briefing says is refused, with the engine's own
documentation as the cause.

# The fix, in the same cut as SM504

- **ai-briefing-publishing**: the brief section rewritten for the store -
  the tools on both channels, the append-only discipline and first-append
  spec, the refusal and what it names, the migration pointer, and the
  wider key space (folders, assets, the site root, brief-first authoring)
  that already worked and nobody had written down.
- **ai-briefing-authoring** step 6: `append_brief`, never a sidecar.
- **ai-connector-tools**: listing metadata claim corrected (left with
  SM245); `delete_page` / `rename_page` / `move_file` now state store
  carriage (SM507).
- **MCP tool descriptions**: `delete_page` and `rename_page` corrected.
- **Dead code**: `createBrief()` removed from the Files panel source -
  never called since SM245's own rework, but a plausible-looking function
  that writes the forbidden sidecar, in the file a future edit would open.
