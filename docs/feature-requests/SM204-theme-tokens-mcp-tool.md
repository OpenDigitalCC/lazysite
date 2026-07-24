---
title: "SM204 - theme_tokens MCP tool (token-vocabulary discovery)"
subtitle: "The first thing any restyling or theme-authoring task needs is the token vocabulary; today that means path-knowledge + read_file + mental CSS parsing. One read tool returns the parsed vocabulary and exemplar values."
brand: plain
status: candidate
status-note: "IMPLEMENTED on main 2026-07-24 (unreleased, 0.9.14 line); scoped from the theme-authoring / Figma design-transfer briefing (item 3). Audited: registration checklist confirmed; reuses existing theme readers. Works standalone in a derived mode; richer once SM203 (declared tokens) lands. Highest-leverage single item for the design pipeline."
---

# SM204 - theme_tokens MCP tool (token-vocabulary discovery)

## Why

The mechanical part of design-transfer - map Figma colour/font variables onto a
theme's `config` - needs a target vocabulary. So does any AI or human building or
restyling a theme. Today that requires knowing the on-disk path, calling
`read_file` on a `theme.json` or a `main.css`, and parsing the tokens out by eye.
One call should return the vocabulary and exemplar values.

## What

New MCP READ tool `theme_tokens`. Capability `manage_themes` (consistent with
`list_themes`). Read - NOT audited.

Arguments (all optional):

- `theme` given: return that theme's parsed `config` (groups, keys, values) plus
  `name`/`version`/`layouts` from its `theme.json`.
- `layout` given, no `theme`: return the layout's declared `tokens` block (SM203)
  if present, PLUS the layout's default theme `config` as exemplar values. If no
  declared block, derive the vocabulary from the default theme's config and mark
  the result `"derived": true`.
- neither: default to the active layout + active theme.

Return shape (sketch):

```json
{ "ok": 1, "layout": "noir", "theme": "noir", "derived": false,
  "tokens": { "colours": {"primary": "#...", "text": "#..."}, "fonts": {"body": "..."} },
  "declared": { "colours": ["primary","text"], "fonts": ["body"] } }
```

## Feasibility (audited)

Registration is the standard five-point MCP tool checklist in `lazysite-mcp.pl`:

1. `%TOOLS` entry (`description`, `cap => 'manage_themes'`, `inputSchema`, `run`).
2. `%ANNOTATE` entry `theme_tokens => [1,0,0]` (read-only, not destructive, not
   open-world).
3. `%READ` set: add `theme_tokens => 1` (so it is NOT audited).
4. `Lazysite::Capabilities` `manage_themes` unlocks list (the `05-capabilities.t`
   guarantee test enforces this).
5. Dispatch + tool-list are automatic once 1-2 are present.

Implementation reuses existing readers: `_read_active_layout_and_theme` and the
theme walk in `Lazysite::Manager::Themes` (`action_themes_list_all` ~88-130) for
discovery, then `decode_json` of the chosen `theme.json` for the `config` block
(which `list_themes` does not currently parse - this is the new read). The
declared-tokens branch reads `layout.json`'s `tokens` (SM203).

## Dependencies

- Fully functional WITHOUT SM203 via the `derived` mode (vocabulary inferred from
  the default theme's config).
- Richer with SM203: the `declared` block gives the authoritative target set
  independent of any one theme's coverage.

## Not in scope

- No write. No render change. No new capability - reuses `manage_themes`.

## Verification

- `theme_tokens` against a layout WITH a declared block (SM203) returns `declared`
  + exemplar; WITHOUT a block returns `derived: true`.
- Against an explicit `theme`: returns that theme's parsed config.
- With neither argument: returns the active layout+theme pair.
- `t/unit/mcp/01-protocol.t`: the tool is advertised in `tools/list` and gated to
  `manage_themes` (SM196 filter). Existing suite green.
