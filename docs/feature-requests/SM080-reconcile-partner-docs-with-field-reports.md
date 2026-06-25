---
title: "SM080 - Reconcile partner docs with CC field reports"
subtitle: "Fold the dhcf + Barn build learnings into the shipped briefings; fix the theme_assets mirror"
brand: plain
---

::: widebox
Two real publishing-partner builds (community.dhcf.eu and The Barn) produced
field reports with concrete documentation recommendations and one real bug.
Several items were already folded into the briefings during the 0.3.x work -
this task is to reconcile the rest, not duplicate. Sources:
`/srv/projects/lazysite-sites/reports/{barn-build-learnings,lazysite-site-build-guide}.md`.
:::

## Status

**Done (2026-06-24, re-validated 2026-06-25).** Both the code work (the
activation asset mirror, pinned by `t/unit/lib/10-theme-mirror.t`) and the
documentation reconciliation are complete (see the DONE sections below); the
"Open documentation work" list was folded into the briefings during that pass.
Future partner reports refresh this from `lazysite-sites/reports/`.

## Already addressed (verify, don't redo)

- Self-serve activation (`theme-activate` / `layout-activate`) replacing the
  stale "operator-only" note - done in the layouts/publishing briefings.
- Embedded-HTML rules (4-space -> code block; blank line -> `<p>`; keep HTML
  flush/contiguous or use a `.md` partial) and the multi-line `::: include`
  requirement - done in the authoring briefing.
- Wiring a form over WebDAV (`<name>.conf` -> `local-storage`; secrets stay
  operator-only) - done.
- `.brief` sidecar convention + edit-to-refactor purpose - done.
- `whoami.scope.deny` now mirrors DAV enforcement, pinned by
  `06-deny-consistency.t` - done.

## Open documentation work

- **"Trust the server" preamble** (highest value): health-check `PROPFIND /dav/`
  (expect 207) and read `whoami` for the true scope/capabilities *before*
  acting; treat brief prose as secondary. One short section at the top of the
  publishing briefing.
- **"Changing a live design" / copy-then-activate**: the active layout tree
  write-locks (`layout.tt`, `theme.json`, `assets/main.css` all 403). Document
  the loop: copy the layout dir -> edit the copy -> activate layout + theme
  **together** (`layout-activate?path=<new>&theme=<new>`; the layout alone is
  rejected when the theme isn't declared for it) -> delete the old. Link CSS
  dir-agnostically with `[% layout_name %]` / `[% theme_name %]`.
- **`theme.json` rules**: ASCII + quote-free values, `main.css` under `assets/`,
  validation runs at activation (re-activate after a fix).
- **Template variables/helpers reference** in one place (`scan:`, `FOREACH`,
  `layout_name`, `theme_name`, `nav`); state plainly there is **no randomness
  primitive** (a "random quote" must be a carousel or build-time pick).
- **Auth gotcha**: the Basic-auth username is the partner id from the brief, not
  a bare "claude".
- **Cache-clear caveat**: activation deletes generated `<page>.html`; author
  partials as `.md` (`.html` now preserved); never hand-run `find ... -delete`.

## Code work - DONE (2026-06-24)

- **Activation asset mirror - fixed.** `_mirror_theme_assets($layout, $theme)`
  now copies the theme's `assets/` to `/lazysite-assets/<layout>/<theme>/` on
  every theme/layout activation (not only on a repo install), so `theme_assets`
  resolves for a copied-then-activated layout and copy-then-activate is
  zero-edit. Pinned by `t/unit/lib/10-theme-mirror.t`.

## Documentation reconciliation - DONE (2026-06-24)

On review, the shipped briefings already carried most of the field-report
guidance (added during the 0.3.x work): the trust-the-server principle ("the
brief describes, the token is, the server enforces" + the `/dav` status guide),
the stage/copy-then-activate loop (`ai-briefing-layouts` "Staging a layout over
WebDAV"), the partner-id auth gotcha, the theme.json ASCII/quote-free +
validate-at-activation rules, and the cache-vs-content `.html` distinction.

Reconciled the remainder this pass:
- Added the **no-randomness** note to `ai-briefing-authoring` (use a carousel /
  build-time pick / `scan` + `FOREACH`, not a per-request random helper).
- Updated the **activation mirror** section in `ai-briefing-layouts` for the
  SM080 fix: the mirror is rebuilt on every activation, so a copied-then-
  activated layout is drop-in (`200` on the mirror) with no CSS-path edits - the
  404-recovery is now a rare fallback, not the expected path.

## Process note

These reports are the canonical "real partner experience" feedback loop; future
builds should keep dropping reports in `lazysite-sites/reports/` and this doc
(or its successor) should be refreshed from them per release.
