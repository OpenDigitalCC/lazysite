---
title: "SM085 - Git backend plugin (content versioning)"
subtitle: "Version the docroot with git; per-asset timelines and rollback"
brand: plain
---

::: widebox
A plugin that puts the docroot under git and commits on every content change, so
each asset has a timeline and any version can be restored. Complements the
audit trail (which records *actions*) with a *content* history, and gives the
migration use case (SM084) a natural backup + rollback.
:::

## Idea

- `git init` the docroot (or adopt an existing repo); initial commit captures the
  current site (great as the pre-migration snapshot for SM084).
- On each manager / WebDAV / MCP write (create / edit / delete / move), commit the
  change with the acting **partner as author** and the audit action as the commit
  message (`edit content/about.md`, `delete old/page.md`, ...).
- Expose history + restore in the manager: per-file log, diff, "restore this
  version". A `git log` per asset is the timeline the operator wants.

## Why a plugin

The plugin API already exists (`plugins/`, `plugin-*` control-API actions). Git
versioning is optional and site-specific, so it fits a plugin rather than the
core: enable it per site, point it at the docroot, and it hooks the write events.

## Open questions / guards

- **Never serve `.git`**: the deny-list MUST refuse `/.git` over the processor,
  WebDAV and the file tools (a leaked repo exposes everything). Non-negotiable.
- Commit cadence: per-write (clean history, more cost) vs debounced/periodic. Per
  write is simplest and matches the audit granularity.
- Author/identity: map the partner to a git author; keep commits attributable.
- Large/binary assets: fine for git but consider size; maybe skip the cache
  (`*.html` generated) and `lazysite/` runtime dirs via `.gitignore`.
- Interaction with SM084 backup: if git is enabled, the initial commit IS the
  pre-install backup; otherwise SM084 uses a tar snapshot.
- Performance under an AI partner doing many small edits (debounce?).

## Status

Queued (design). Raised 2026-06-25 alongside SM084. The overlay-migration work
(SM084) ships the tar-snapshot backup; this plugin is the richer, opt-in
versioning layer and its initial commit can serve as that backup when enabled.
