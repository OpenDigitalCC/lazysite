---
title: "SM205 - create_theme MCP tool (validated theme scaffolding) + eager theme.json validation"
subtitle: "Creating a theme over the connector is a five-step sequence with three documented sharp edges (nested dirs, validation only at activation, assets-must-live-under-assets/). Collapse it into one validated write; and make theme.json writes validate eagerly like page writes do."
brand: plain
status: candidate
status-note: "IMPLEMENTED on main 2026-07-24 (unreleased, 0.9.14 line); scoped from the theme-authoring / Figma design-transfer briefing (item 4). Audited: the activation validator is STRUCTURAL-ONLY, so eager value-validation is new (mirror the render-time strip rule); the terminus of the Figma pipeline lands here. Moderate. Best after SM203 (coverage check) but not blocked by it."
---

# SM205 - create_theme MCP tool (validated theme scaffolding)

## Why

Creating a theme via the connector today means: create nested directories through
`write_file` paths, write `theme.json` (whose validation runs only AT ACTIVATION,
and is cached - so a fix needs re-activation, not just re-PUT), remember assets go
under `assets/` (a root-level `main.css` silently 404s after the mirror), write the
CSS, then activate. Every one of those sharp edges is individually documented in
`ai-briefing-layouts` because every one has burned someone. The Figma pipeline's
terminus is literally "a config block plus optionally CSS" - this tool is its
natural landing, and it pays off for every theme-authoring task.

## What

New MCP WRITE tool `create_theme`. Capability `manage_themes`. Write - AUDITED
(one audit event for the scaffold; a requested activation audits as itself).

Behaviour:

- Validate inputs EAGERLY and return structured errors before writing anything:
  - `name` sanitised to `[A-Za-z0-9_-]`.
  - `config` values are strings, ASCII, no `;{}<>` (the same characters the
    render-time emitter strips - see below).
  - `layout` exists and is installed.
- If the layout declares `tokens` (SM203): a coverage check returned as WARNINGS
  (declared tokens the theme omits, with the layout-CSS fallback values that will
  apply; supplied undeclared tokens). Warn, never reject.
- Scaffold `lazysite/layouts/LAYOUT/themes/NAME/` with `theme.json`
  (`layouts: [LAYOUT]`, `author` from the partner identity, `version` default
  `1.0.0`) and `assets/main.css`.
- `css` omitted: copy the layout default theme's `main.css` as the starting point.
  This encodes copy-nearest-and-adapt: the `config` tokens restyle it immediately
  via the `var(--theme-*)` fallback chain; CSS craft can follow.
- `activate: true` (default false): run the existing activate path (mirror build +
  cache clear), same as `activate_theme`.
- Return created paths, warnings, and preview guidance (the source-CSS preview URL
  pre-activation; the mirror URL post-activation).
- Errors follow the existing `{ ok: 0, error, kind }` model; add `kind:
  "validation"` carrying the specific failing rule so an agent can fix without
  re-reading docs.

Folded-in smaller fix: `theme.json` written via the general `write_file` path
SHOULD also run the theme validator eagerly and return warnings, mirroring how
`write_file` already runs `_validate_page` for pages (`lazysite-mcp.pl` ~335-348).
This removes the fix-then-must-reactivate trap for an agent editing an existing
`theme.json`.

## Feasibility (audited) - one correction to the premise

The briefing assumes create_theme can "reuse the activation validator" for value
rules. The audit shows the activation validator `_validate_theme_dir`
(`lib/Lazysite/Manager/Themes.pm` ~236-258) is STRUCTURAL ONLY: it checks the file
exists, parses as JSON, has a non-empty `layouts[]`, and that the active layout is
listed. It does NOT sanitise config values or the name.

Where the value rules actually live is the render-time emitter
`generate_theme_css` (`lazysite-processor.pl` ~4285-4313), which strips `;{}<>`
from every value before emitting. So today a "bad" value does not inject - it is
silently stripped at render. The eager value-validation in create_theme is
therefore a clarity/UX safeguard (tell the author up-front that a value carries
characters that will be stripped, or a name that will be rejected), NOT a new
security boundary. Implementation:

- Author a small shared `theme_config_issues(\%config, $name)` helper applying the
  name rule (`[A-Za-z0-9_-]`) and the value rule (ASCII, no `;{}<>` - the SAME
  characters `generate_theme_css` strips, kept in sync). Call it from create_theme
  (eager, returns `kind: validation`) and from the `write_file` theme.json hook
  (warnings). Consider also calling the structural `_validate_theme_dir` at both
  points so activation and creation agree.
- Reuse `Lazysite::Manager::Themes` for the scaffold write, the default-theme
  `main.css` copy source, and the activate/mirror path (`action_theme_activate`
  ~132-178, `_mirror_theme_assets` ~222-234).

Registration (write+audited tool) in `lazysite-mcp.pl`:

1. `%TOOLS` entry (`cap => 'manage_themes'`, schema, `run`).
2. `%ANNOTATE` entry `create_theme => [0,0,1]` (not read-only; open-world - it
   changes the site).
3. Do NOT add to `%READ` (absence is what triggers audit logging).
4. Audit action-label for `create_theme` (e.g. `theme-create`) in the audit map
   alongside `write_file => 'create'`.
5. `Lazysite::Capabilities` `manage_themes` unlocks (guarantee `05-capabilities.t`).

## Not in scope

- Changing the render-time emission or its strip rule.
- Hard rejection on a token-coverage mismatch (warnings only).
- Exposing any theme write path to a partner lacking `manage_themes`.

## Verification

- Happy path: `create_theme` with ONLY a `config` (default CSS copied) renders via
  the preview URL.
- Eager validation: a non-ASCII description / a name with a space is rejected with
  `kind: "validation"` naming the rule, before any file is written.
- Coverage warnings fire against a declared-tokens (SM203) layout when the theme
  omits a declared token.
- `write_file` of a `theme.json` returns the same validator warnings without
  requiring activation.
- `t/unit/mcp/01-protocol.t` advertises + gates the tool; the audit trail records a
  `theme-create` event. Existing suite green.
