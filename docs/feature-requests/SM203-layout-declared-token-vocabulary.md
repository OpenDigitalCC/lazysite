---
title: "SM203 - Declared token vocabulary in layout.json"
subtitle: "Which theme tokens a layout's reference CSS consumes is discoverable only by grepping an existing theme's main.css. Add an OPTIONAL, declarative tokens block to layout.json so the layout<->theme contract is explicit and machine-readable - documentation-as-data, never enforced at render."
brand: plain
status: shipped
status-note: "IMPLEMENTED on main 2026-07-24 (unreleased, 0.9.14 line); scoped from the theme-authoring / Figma design-transfer briefing (item 2). Audited: layout.json already tolerates unknown keys (harmless to add), the render-time --theme-* emission is settled and untouched, backfill is a straightforward grep across the 25 layouts. Enables SM204/SM205."
---

# SM203 - Declared token vocabulary in layout.json

## Why

A layout's reference CSS consumes specific CSS custom properties
(`var(--theme-colours-primary, ...)` and friends). A theme supplies them through
its `theme.json` `config` block, which the processor turns into `--theme-GROUP-KEY`
declarations. But NOTHING declares the contract: the set of tokens a layout's CSS
actually consumes is discoverable only by reading an existing theme's `main.css`
and grepping for `var(--theme-`. Every theme author - human, AI, or a mechanical
Figma-variable mapper - reverse-engineers the vocabulary from scratch.

The design-transfer work (translating a Figma palette into a lazysite theme)
exposed this as the structural gap: the mechanical part (map palette -> config)
has no declared target to map ONTO.

## What

`layout.json` gains an OPTIONAL `tokens` block naming the token vocabulary the
layout's reference CSS consumes, grouped as the config is:

```json
"tokens": {
  "colours": ["primary", "text", "heading", "background", "border", "accent"],
  "fonts":   ["body", "heading", "code"]
}
```

Semantics:

- DECLARATIVE, NOT ENFORCED at render time. The processor's emission
  (`generate_theme_css`, `lazysite-processor.pl` ~4285-4313: walk `theme.config`,
  emit `--theme-GROUP-KEY`, strip `;{}<>` from values) is UNCHANGED. This spec adds
  no render behaviour.
- A theme MAY supply extra tokens (its own CSS may consume them); a theme MAY omit
  declared tokens (the layout CSS `var(--theme-*, <fallback>)` covers it). The
  block is documentation, not a schema gate.
- The manager MAY warn (never reject) at theme activation/upload when a theme for
  this layout is missing declared tokens or supplies undeclared ones. Warn-only:
  the fallback chain makes mismatches survivable by design, and hard rejection
  would break the deliberate loose coupling. Hook: after the existing
  `_validate_theme_dir` structural check in `Lazysite::Manager::Themes`
  `action_theme_activate` (~156-178), emit a non-fatal `log_event('WARN', ...)`
  comparing declared vs supplied token sets.

## Feasibility (audited)

- `layout.json` is parsed with `decode_json` and only known keys are read
  (`_layout_default_theme` in `lazysite-processor.pl` ~4274-4283;
  `_install_layout_from_dir` in `lib/Lazysite/Manager/Layouts.pm`). Unknown keys
  are silently ignored, so adding a `tokens` block is harmless to every existing
  code path today - confirm during implementation, but the audit found no parser
  that rejects unknown keys.
- The 25 layouts in `/srv/projects/lazysite-layouts/layouts/` each ship a default
  theme whose `main.css` uses a small, regular vocabulary (~16 distinct
  `--theme-*` names observed, e.g. `colours-primary`, `colours-text`,
  `colours-heading`, `fonts-body`, `fonts-code`).

## Backfill

A `tools/` script in the layouts repo generates each layout's `tokens` block by
grepping its default theme CSS for `var(--theme-([a-z]+)-([a-z-]+)` and grouping
the captures. Add a layouts-repo lint asserting the declared block matches the
greppable reality of the default theme (the repo currently has no test harness -
this is the first). Ship the generated blocks into the 25 `layout.json` files.

## Not in scope

- Any change to the render-time `--theme-*` emission (settled, correct).
- Hard rejection anywhere on a token mismatch. Warnings only - the fallback chain
  is a designed property.
- Adding spacing/type-scale token slots. The minimal-token model (identity in
  tokens, rhythm/scale in CSS) is a deliberate strength; this spec documents the
  existing vocabulary, it does not grow it.

## Verification

- A layouts-repo lint: each layout's declared `tokens` matches a fresh grep of its
  default theme's CSS.
- The engine ignores the new block: existing layout install/activate tests stay
  green with `tokens` present in a fixture `layout.json`.
- Activation of a theme missing a declared token logs a WARN and still succeeds.
