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

**Phase 1 core BUILT (2026-07-10).** `lib/Lazysite::Git` (init / auto-commit /
log / show / diff / `run_git` plumbing), the write hooks (manager save, delete,
move, copy, migrate-to-local, upload; WebDAV PUT/DELETE/MOVE/COPY; nav-save and
config saves; backup restore), the `git-init` / `git-status` / `git-history` /
`git-show` / `git-restore` control-API actions, the Files-app history panel
(view / diff / restore) and the Backups-page "Content history" card, plus the
lazysite-check probes (git binary, repo perms, the auth-exclusion SECURITY
probe). The git-sync REMOTE plugin (push/pull, collision handling) is the
separate follow-up and calls the same `Lazysite::Git` module.

Raised 2026-06-25 alongside SM084. The overlay-migration work (SM084) ships
the tar-snapshot backup; this is the richer, opt-in versioning layer and its
initial commit serves as that backup when enabled.

## Design decisions (2026-07-10, build approved)

Repository placement - never web-reachable
: GIT_DIR lives at `lazysite/git/` (inside the protected, never-served
  lazysite/ tree) with the docroot as the work tree
  (`git --git-dir=<docroot>/lazysite/git --work-tree=<docroot>`). No `.git`
  under the docroot means nothing for the web server to leak, and no
  deny-rule to depend on (defence stays in depth: the processor/DAV deny
  lists refuse `/.git` anyway). Ignore rules live in `GIT_DIR/info/exclude`,
  not a docroot `.gitignore` - the operator's site gains no new visible file.

What is versioned (the "will it include config?" answer)
: The content tree (every operator-authored file under the docroot) PLUS the
  two operator-authored config files: `lazysite/lazysite.conf` and
  `lazysite/nav.conf`. NEVER versioned (info/exclude, written at init):
  `lazysite/auth/` (secrets, credential hashes, session registry),
  `lazysite/forms/` (submission PII + SMTP secret), `lazysite/notify-xmpp.conf`
  (XMPP password), `lazysite/cache/`, `lazysite/logs/` (visitor data),
  `lazysite/backups/`, `lazysite/manager/locks/`, `lazysite/git/` itself,
  generated `*.html` siblings and `lazysite-assets/` mirrors, `.install-state`
  artefacts. Rationale: history must be safe to sync to a REMOTE - a repo that
  can be pushed must never contain a secret or personal data. `aliases.json`
  is regenerable (derived from front matter) and excluded.

What this does to backups
: Git becomes the day-to-day content history: every save is a commit, so
  "restore yesterday's page" stops being a tar-snapshot operation. The
  existing backups stay, with sharpened roles - FULL-SYSTEM backups remain
  the DR mechanism (they carry exactly what git deliberately excludes:
  secrets, auth store, submissions) and are untouched; CONTENT backups
  remain available (belt-and-braces, and the path for sites that keep git
  disabled), and the SM084 pre-restore safety snapshot stays. Two
  integrations: enabling git makes its INITIAL commit the adoption snapshot,
  and a content-backup RESTORE commits the restored state (restores are
  visible history, not history erasure).

Commit model
: Per-write auto-commit (matches audit granularity): every manager, DAV and
  MCP content write commits with the acting user as author
  (`user <user@site>`) and the action as message. Batched operations (a
  directory move) are one commit. The audit trail records actions; git
  records content - same actor attribution in both.

Files-app history (the step-through)
: Each file row gains History: a panel listing that file's commits (when,
  who, what action); selecting a version shows its rendered-source diff
  against current and a View of that version's raw content; Restore writes
  the old version back through the normal save path (so the restore is
  itself a commit, cache-invalidated, audited - no divergent write path).

Remote sync - the git-sync plugin (alongside, opt-in)
: A plugin (enable on Plugin Manager, configure on Plugin Config): remote
  URL + branch + credential (token in a password-type field, stored 0660 per
  the SM139-era rule). Two actions, on demand only: PUSH (local history to
  the remote branch) and PULL. Basic collision management without git
  vocabulary: a pull that fast-forwards just applies; when both sides
  changed, the operator sees the plain-language conflict list ("These pages
  changed in both places: ...") and chooses KEEP MINE or TAKE THEIRS for the
  operation (merge -X ours/theirs under the hood); either way a safety
  snapshot is taken first and the outcome is audited. No branches, no merge
  UI, no rebase - ever. The remote is expected to be a private repo
  (Forgejo); the exclude rules above are what make pushing safe.

Phases
: Phase 1 (this build): core module + auto-commit hooks + Files-app history/
  step-through/restore (CORE, built 2026-07-10) + the git-sync plugin
  (separate follow-up build on the same core). Phase 2 (future): the agent
  changeset workflow (begin -> diff -> commit -> rollback as MCP/API
  session), periodic auto-push schedules, history for config files in the
  manager UI.
