---
title: "SM084 - Non-destructive overlay install + inline migration"
subtitle: "Deploy lazysite onto a live HTML/SSI site and migrate page by page"
brand: plain
---

::: widebox
Use case: deploy lazysite onto an **existing** static HTML / SSI site and migrate
to lazysite **inline** - without deleting any existing HTML, `.shtml`, SSI
includes, assets or `index`. Existing pages keep serving until a Markdown version
replaces them, one at a time.
:::

## Why the current installer is unsafe here

On a docroot that already has real content:

- `install-hestia.sh` creates a starter `index.md` when none exists.
- `lazysite-hestia-deploy.sh` then runs
  `[ -f index.html ] && [ -f index.md ] && rm -f index.html` to clear the Hestia
  stub - which now **deletes the site's real `index.html`** because the step above
  just created an `index.md`.

Net: a live `index.html` is replaced by the starter page. Other static files are
left alone today, but the pattern (install starter content + clear "stub" HTML)
is the hazard.

## Wanted

1. **Overlay install mode** (`--overlay` / `--migrate`): install ONLY the
   infrastructure - `lazysite/`, `manager/`, `cgi-bin/*.pl`, `.well-known/`,
   assets - and **never** create starter content pages or delete any existing
   file. No `index.md` seeded; no `index.html` removed. The processor already
   serves an existing `.html`/`.shtml` directly and only renders `<page>.md` when
   present, so a static site keeps working untouched and a page is migrated by
   adding its `.md`.
2. **Content backup before first touch** - like the theme backup. Snapshot the
   whole docroot (tar to `lazysite/backups/preinstall-<stamp>.tar.gz`, excluding
   `lazysite/`) so the original is always recoverable.
3. **Optional `git init`** of the docroot, initial commit = the original site, so
   git tracks each asset's timeline. If adopted for ongoing use, lazysite writes
   (manager / WebDAV / MCP) could auto-commit with the acting partner as author -
   a content-level history complementing the (action-level) audit trail. Guard:
   the deny-list MUST refuse `/.git` (never serve the repo); `.git` excluded from
   WebDAV + the processor.
4. **Inline migration workflow** doc: existing `.html`/`.shtml`/SSI served as-is;
   create `<page>.md` to migrate that page (it renders over the old `.html`);
   verify; repeat. A "migrate this page" helper (seed a `.md` from the rendered
   HTML) would be a nice follow-on.

## Open questions

- Backup mechanism: tarball snapshot vs `git init` vs both. Git gives timelines +
  rollback per asset; tar is simpler and external. Likely: tar snapshot always,
  git as an opt-in that also enables ongoing versioning.
- Auto-commit on write: per-write commit (clean history, more cost) vs periodic.
  Author = the partner; message = the audit action (create/edit/delete <path>).
- SSI: confirm the processor/vhost lets Apache keep handling `.shtml` + SSI for
  un-migrated pages (FallbackResource only catches misses).
- `index` precedence during migration: `DirectoryIndex index.html index.htm`
  means the static index wins until the operator chooses to migrate it (then they
  add `index.md` and remove the old `index.html` deliberately - never the
  installer).

## Status

In progress (2026-06-25).

- **Done - non-destructive index.html (narrowed delete, no overlay flag).** Rather
  than an overlay install mode (which could be forgotten, leaving the same
  hazard), the delete is narrowed: `install-hestia.sh` clears `index.html` ONLY
  when `index.md` already existed (so it was the cache rendered from it). A
  freshly-seeded `index.md`, or a static-site overlay, leaves an existing
  `index.html` untouched; `deploy.sh` no longer deletes it (it just warns if a
  placeholder shadows a new `index.md`). lazysite can now be installed over a live
  HTML/SSI site without losing the homepage.
- **Done - content backups.** A one-time pre-install tar snapshot of the docroot
  (excluding `lazysite/`) is taken by the Hestia hook the first time lazysite is
  installed over existing content, stored at `lazysite/backups/preinstall-*.tar.gz`.
  A new manager **Backups** page lists them, takes manual snapshots on demand, and
  downloads them; `lazysite/backups/` is infrastructure and never served.
- **Moved out - git versioning** is now its own opt-in plugin, [[SM085]]; its
  initial commit can serve as the backup when enabled.
- **TODO - restore.** Backups can be listed, created and downloaded, but there is
  no in-manager **restore** (re-extract a snapshot over the docroot). Add a
  guarded "Restore this snapshot" action (confirm + take a fresh pre-restore
  backup first; never touch `lazysite/`). Raised 2026-06-25.

SM084 is now complete: non-destructive install + content backups. Inline page-by-
page migration works on top (existing HTML/SSI served until a `.md` replaces it).

## Progress (2026-06-27): SSI overlay support

The lazysite-app Apache template now overlays an existing **static SSI** site
non-destructively: `DirectoryIndex` includes `index.shtml`, and the docroot enables
`Options +Includes` + `AddOutputFilter INCLUDES .shtml` (needs `a2enmod include`). An
existing `index.shtml` homepage is served (and SSI-processed) so lazysite's markdown
fallback never shadows it; markdown/missing paths still fall through to the processor.
PHP/dynamic overlay remains out of scope for this template (no PHP handler) - the broader
non-destructive-overlay design is still the full SM084. Runbook documents the overlay
flow and the "remove a previously-rendered index.html" remediation.
