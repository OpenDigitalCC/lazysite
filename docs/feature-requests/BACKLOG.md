---
title: "Feature-request backlog (index)"
subtitle: "Status at a glance; see each SMxxx doc for detail"
brand: plain
---

One-line status for every feature request. Updated 2026-06-28. Status derived
from the CHANGELOG (shipped releases) and corroborating code, not the per-doc
text.


## Ideas - not yet scoped

Discrete items expanded from the raw wishlist; each needs its own scoping doc
before work starts.

- **Plugin packaging / separation** - split plugins from the core tree so they
  can be added, removed, or uploaded independently. A plugin becomes a
  self-describing unit installed/uploaded like a theme, rather than living in the
  core checkout.
- **Calendar-booking plugin** - bookable time slots with availability, producing
  a booking record (ties to the forms + notifications stack).
- **Live-chat plugin (XMPP bot)** - an on-site chat widget backed by an XMPP bot
  (reuses the existing XMPP integration).
- **E-commerce via Odoo** - products, prices, and sales sourced from Odoo's
  e-commerce API; an on-site basket creates a sales order through that API. No
  local product/price store - Odoo is the source of truth.
- **Passkey auth extension** - WebAuthn / passkey login delivered as an auth
  plugin.
- **Database plugin** - pluggable storage (JSON file / SQLite / DBI) with a
  "form -> DB" write path. Named schemas (session, profile, basket, log,
  comments, + arbitrary); values readable and writable in TT, enabling
  author-built dynamic content.
- **AI-filter plugin** - send data plus an instruction to an AI vendor
  (selectable vendor + dev key in settings) for form review, moderation, and
  other transform tasks.
- **Search improvements** - feed both the auto-index and a manual index; log
  failed searches to a file for review.


## Done

- **SM070** WebDAV publishing endpoint + per-user ACLs.
- **SM071** WebDAV theme/layout management; self-service activation.
- **SM072** Self-service credentials + MFA-ready auth.
- **SM073** Per-file `.brief` sidecars.
- **SM074** Per-file ownership + ACLs.
- **SM076** MCP server for site management + OAuth (Claude.ai / ChatGPT / Code).
- **SM077** File-manager UI overhaul (permissions, rename/move, rights editor).
- **SM078** Audit trail records the target + origin.
- **SM079** Modular refactor (standalone processor + `Lazysite::*` modules); **SM079a** action-handler decomposition.
- **SM080** Reconcile partner docs with field reports (+ activation asset mirror).
- **SM081** Form targets: mixed handler/type read fixed (single-pass parse).
- **SM082** Content vs theme/layout write capability (`manage_content`).
- **SM083** Access-log stats plugin (domain-qualified auto-detect, autoconfig);
  v2 (0.4.62) adds a traffic classifier (people / AI assistants / bots / noise /
  logged-in operator), internal/external/direct referrer split, log-path privacy
  + log download, and a nav item hidden when the plugin is disabled.
- **SM084** Non-destructive overlay install + content backups *(restore: still open, below)*.
- **SM087** Connector editing ergonomics - full tool set (patch edit, search, preview, validate, `set_nav`, copy, permissions, audit, manifest, error kinds, nav-cache).
- **SM088** Form-to-transport binding (`list_form_handlers` / `bind_form`).
- **SM091** Dev-server auto-index (`tools/lazysite-server.pl --auto-index`).
- **SM093** One-command manager bootstrap.
- **SM094** Users-page permission clarity.
- **SM097** Nav-editor page autocomplete.
- **SM099** Client-side auth button (`data-ls-auth-*` sync before `</body>`).
- **SM100** One-connect flow (connector onboarding).
- **SM101** Agent stop-retrying signal.
- **SM102** Agent feedback endpoint.
- **SM104** Top-level vs sub-user clarity.
- **SM105** Per-section `nav` own-capability; **SM106** `forms` own-capability.
- **SM107** Manager access-groups picker (delivered under SM114).
- **SM108** AI form-building docs.
- **SM109** Manager UI modernization (shell + sidebar, palette, toasts, dark mode).
- **SM111** Files list sortable + paginated.
- **SM112** Generated-site `<meta name="generator">`.
- **SM113** Operator notifications + submission alerts.
- **SM114** Manager UI polish round 2 (incl. access-groups picker).
- **SM115** Submissions UX + safety (append-only data read-only).
- **SM116** Dark editor colour scheme (WCAG-tuned CodeMirror).
- **SM117** Audit install/upgrade events.
- **SM118** Settings unsaved-changes reminder.
- **SM119** Audit filter dropdowns + date-range search.
- **SM120** Per-page `theme:` override.
- **SM121** WebDAV provisioning.
- **SM122** Token config self-service.
- **SM123** Theme discovery.
- **SM124** Connector onboarding alignment.
- **SM125** Scan front-matter passthrough.

## Open - actionable

- **SM085** Git backend / changesets *(design)* - `begin → diff → commit →
  rollback` on a git-versioned docroot. Biggest remaining lever; adds the
  rollback safety net. Headline ask from both AI-partner reviews.
- **SM084 restore** - in-manager "restore this snapshot" (list/create/download
  exist; restore does not).
- **SM095** Group-based partner capabilities - extend the operator domain's
  group model to the partner (WebDAV / content / theme / sub-user) capabilities.
- **SM096** "Migrate to local" - one click to fetch a `.url` page's body and
  take local ownership as `.md`.
- **SM098** Multi-page / wizard forms (Next / Back, per-step validation).
- **SM103** Recent-change markers - "changed recently" dots on nav/users/files;
  the visible tip of a streaming audit-trail layer.
- **SM110** Domain aliases - an additional host serving the same site with its
  own theme / nav / name.
- **Sessions page - active-session details** - the new Sessions page exposes only
  "log out everyone" (rotate the auth secret). List active sessions with detail
  (who / where / when / last seen) so individual sessions are visible and ideally
  revocable.
- **theme_assets fallback on no active theme** - when a layout is previewed or
  set per-page with no compatible active theme, `theme_assets`/`theme_css` are
  empty and the page renders unstyled. Fall `theme_assets` back to the layout's
  `default_theme` mirror (if installed) so preview looks right without every
  layout needing its own `[% ELSE %]` fallback link.
- **Remote-layout content components** - `install_layout` + fenced/sections
  components are local-layout only; remote (URL) layouts fetch just `layout.tt`,
  so their `components/` are not fetched or resolved. Bundle + resolve components
  for remote layouts if remote layouts get more use.
- **Visitor statistics - performance + visualisations** - the stats scan is
  synchronous and re-reads the whole log each load. Make it faster (cache the
  computed result, or stream/async so the tiles populate as data arrives) and add
  visualisations (charts for the per-day trend, the class breakdown, referrers).

## Candidates - research / future

- **SM075** Wildcard multi-tenant hosting.
- **SM086** Pandoc-wrapper construct renderers (datatable, charts, `:::` boxes,
  citations) - one source → branded PDF + web.
- **SM090** Social syndication / POSSE (ActivityPub + AT Proto, Slice 1).
- **SM092** Gopher and Gemini services - stays here: a protocol *transport* over
  the shared content core (like WebDAV / MCP), not a visual layout.

*(SM089 3D-rendered layout moved to `lazysite-layouts` - it is a layout/theme
category. Proposal now at `lazysite-layouts/docs/proposals/3d-layout.md`.)*

## Notes

- Every issue from the live Claude.ai / ChatGPT connector reviews (UTF-8,
  front-matter quotes, multi-word `select:`, fenced-div Markdown, tool discovery,
  in-channel verify, etc.) is closed as of 0.4.16.
- 0.4.54-0.4.57 (not SM-tracked): `?v=<version>` asset cache-buster; blank-editor
  fix (auth-sync injected before the real `</body>`, with regression test); nginx
  reload on deploy made opt-in (`LAZYSITE_RELOAD_NGINX`).
- 0.4.58-0.4.67 (not SM-tracked): **Appearance page** (manager "Themes" renamed;
  active layout/theme switcher moved off Config; manager nav/title naming
  standardised); **per-layout install/delete** from a manifest catalogue over the
  UI, control API and MCP (`layout-install`/`layout-delete`/`layouts-manifest`,
  `install_layout(update:true)`); **stats v2** (see SM083); **content components
  (D035)** - layout-owned `components/*.tt` invoked from Markdown via fenced
  `::: name` blocks or front-matter `sections:`, plus a `markdown` TT filter
  (bundled into the layout zip and installed on a site).
- New partner-build reports land in `lazysite-sites/reports/` and refresh SM080.
