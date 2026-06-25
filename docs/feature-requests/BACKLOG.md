---
title: "Feature-request backlog (index)"
subtitle: "Status at a glance; see each SMxxx doc for detail"
brand: plain
---

One-line status for every feature request. Updated 2026-06-25.

## Done

- **SM070** WebDAV publishing endpoint + per-user ACLs.
- **SM071** WebDAV theme/layout management; self-service activation.
- **SM072** Self-service credentials + MFA-ready auth.
- **SM073** Per-file `.brief` sidecars.
- **SM074** Per-file ownership + ACLs.
- **SM076** MCP server for site management + OAuth (Claude.ai / ChatGPT / Code).
- **SM077** File-manager UI overhaul (permissions, rename/move, rights editor).
- **SM078** Audit trail records the target + origin.
- **SM079** Modular refactor (standalone processor + `Lazysite::*` modules).
- **SM080** Reconcile partner docs with field reports (+ activation asset mirror).
- **SM081** Form targets: mixed handler/type read fixed (single-pass parse).
- **SM082** Content vs theme/layout write capability (`manage_content`).
- **SM084** Non-destructive overlay install + content backups *(restore: TODO)*.
- **SM087** Connector editing ergonomics - the full tool set (patch edit, search,
  preview, validate, page-aware API incl. `set_nav`, copy, permissions, audit,
  manifest, error kinds, nav-cache). Complete.
- **SM088** Form-to-transport binding (`list_form_handlers` / `bind_form`).

## Open - actionable

- **SM085** Git backend / changesets *(queued, design)* - `begin → diff → commit
  → rollback` on a git-versioned docroot. Biggest remaining lever; adds the
  rollback safety net. Headline ask from both AI-partner reviews.
- **SM084 restore** - in-manager "restore this snapshot" (list/create/download
  exist; restore does not).
- **SM083** Access-log stats plugin *(queued)* - modern awstats/webalizer from the
  web-server access log; complements the material-events audit trail.
- **SM075** Wildcard multi-tenant hosting *(candidate)*.

## Candidates - research / future

- **SM086** Pandoc-wrapper construct renderers (datatable, charts, `:::` boxes,
  citations) - one source → branded PDF + web.
- **SM089** 3D-rendered site layout (leverages the D013 layout/theme split).
- **SM090** Social syndication / POSSE (ActivityPub + AT Proto, Slice 1).

## Notes

- Every issue from the live Claude.ai / ChatGPT connector reviews (UTF-8,
  front-matter quotes, multi-word `select:`, fenced-div Markdown, tool discovery,
  in-channel verify, etc.) is closed as of 0.4.16.
- New partner-build reports land in `lazysite-sites/reports/` and refresh SM080.
