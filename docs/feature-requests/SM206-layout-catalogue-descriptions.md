---
title: "SM206 - Layout catalogue descriptions and tags"
subtitle: "list_layout_catalogue returns name/version/default_theme/themes only. 25 layouts with evident personalities, but nothing machine-readable expresses purpose - an agent choosing a base layout must guess from names or install-and-inspect."
brand: plain
status: candidate
status-note: "IMPLEMENTED on main 2026-07-24 (unreleased, 0.9.14 line); scoped from the theme-authoring / Figma design-transfer briefing (item 5). Audited: trivial code (manifest field + one passthrough loop); the backfill is a reviewed writing pass. Independent - can land any time."
---

# SM206 - Layout catalogue descriptions and tags

## Why

`list_layout_catalogue` returns `name` / `version` / `default_theme` / `themes` /
`installed` per layout. The 25 layouts have evident personalities (folio, reel,
press, console, publicsector, ...), but nothing machine-readable expresses
*purpose*. An agent choosing a base layout for a client site - or the design
pipeline choosing the nearest layout to adapt - must guess from names or
install-and-inspect each.

## What

- Add per-layout `description` (one line) and optional `tags` (audience/style
  keywords) to the layouts-repo catalogue manifest
  (`/srv/projects/lazysite-layouts/manifest.json`, schema v1).
- Pass them through in `action_layouts_manifest`
  (`lib/Lazysite/Manager/Layouts.pm` ~864-912) - add `description => $l->{description}
  // ''` and `tags => (ref $l->{tags} eq 'ARRAY' ? $l->{tags} : [])` to the
  per-layout hash the loop pushes. The engine already tolerates unknown manifest
  keys, so this is purely additive.
- Backfill the 25 entries.

## Feasibility (audited)

Trivial code: one manifest field and one passthrough line; no validation, no render
or capability change. Note the per-layout `layout.json` files already carry a
`description` field, but several are stubs (e.g. `"Noir layout."`, `"Folio
layout."`) while others are good (e.g. pulse's is descriptive). The manifest is the
catalogue's source, so the real work is: (a) ensure `manifest.json` carries a
`description`/`tags` per layout, and (b) write good one-liners - a reviewed AI pass
over each layout's default theme + a render is well suited, but the copy needs human
sign-off (it is client-facing guidance).

## Not in scope

- Any change to how layouts install or activate.
- Free-text that duplicates `themes[]`/`version` already returned.

## Verification

- `list_layout_catalogue` returns `description` (and `tags` where set) for every
  layout; absent fields degrade to `''`/`[]`, not errors.
- A layouts-repo lint (shared with SM203's, if that lands): every manifest layout
  has a non-empty `description`.
