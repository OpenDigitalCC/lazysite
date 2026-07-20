---
title: "SM183 - Site-package migration in the manager UI (surface parity)"
subtitle: "Let a human perform the agency demo -> client hand-off without MCP or the CLI; make the package the interface across every surface"
brand: plain
status: partial
status-note: "v1 built on claude/sm183-site-package-ui for 0.9.6 (UI-only): Export on Domains; a Site packages panel on Backups (list/download/upload/apply/delete) with an apply preview + confirm; new read action site-backup-inspect + site-backup-delete (manage_domains + scope + lazysite-site- name confinement). DEFERRED: dry-run content diff, one-click rollback + MCP site_apply snapshot parity, target-readiness (domain Check) in the apply flow, integrity sha display, and presentation-key remap override."
---

# SM183 - Site-package migration in the manager UI

## Why

SM158 made a domain's site portable - one domain's content + nav override +
referenced theme/layout + presentation keys, with no plugins, no instance
settings and **no secrets** - so it is safe to hand to a client's own instance.
That is the headline use case: an agency builds a demo on a shared instance and
hands it to the client.

But for a **human**, that flow is headless. The create / upload / apply actions
exist only on the control-API, MCP (`site_backup` / `site_apply`) and the CLI
(`lazysite-site`). There is no affordance on the Domains or Backups page. A
content owner who holds `manage_domains` but does not run an agent or a shell
cannot perform the very hand-off the feature was built for.

## What

Expose the existing site-package family in the manager UI, and make the surfaces
**interchangeable** so the artefact - not the tool - is the interface:

- create a package from **any** surface (UI export, MCP `site_backup`, CLI); and
- consume it from **any** surface (UI apply, MCP `site_apply`, CLI).

Both round-trips must work symmetrically:

- **MCP creates, human applies:** an agent runs `site_backup shop.clienta.com`;
  the operator sees the package in the UI, downloads it, carries it to instance
  B, uploads it, and applies it - no agent on instance B.
- **Human creates, agent applies:** the operator exports a site in the UI and
  downloads it; an agent on instance B uploads (or is handed the file) and runs
  `site_apply`.

This is already structurally true - every surface reads and writes the same
`lazysite/backups/` directory, and `backup-list` already tags a package
`kind => 'site'`. SM183 makes it visible and operable for humans, and pins the
parity with tests.

## v1 as built (0.9.6, UI-only)

Delivered on `claude/sm183-site-package-ui`:

- **Domains page:** an *Export site* button per domain (with its own content
  root) calling `site-backup-create`.
- **Backups page:** a *Site packages* panel that lists `kind: site` entries
  (fixing a prior mis-bucketing that put them in the content list with a wrong
  Restore), with *Download*, *Apply* and *Delete*, plus an *Upload* control.
  Apply opens an inline panel with a manifest **preview** (source host, file
  count, theme/layout/nav), a target picker (a registered domain, or the primary
  site), a *clean* option, and a confirmation naming the target and the
  presentation keys it will rewrite.
- **Backend:** two new actions - `site-backup-inspect` (read the manifest without
  applying; `package_inspect` reuses the M-TAR-safe extractor) and
  `site-backup-delete` - both `manage_domains` + scope + confined to the
  `lazysite-site-` namespace (a full/content backup or an arbitrary path is
  unreachable). Fixed the `action_site_backup_apply` comment/gate drift.

Deferred (tracked in the status note, and detailed under *Related features*):
the dry-run content diff, one-click rollback + MCP `site_apply` snapshot parity,
the target-readiness (domain Check) hook in apply, an integrity `sha`, and the
presentation-key remap override.

## Design (mostly front-end; the backend already exists)

Reuse the shipped actions verbatim - none of them need changing:

- `site-backup-create` (per host) - export.
- `site-backup-upload` (multipart; already rate-limited, name-forced to
  `lazysite-site-uploaded-<stamp>.tar.gz`, non-extracting) - import between
  instances.
- `site-backup-apply` (name, host, clean; isolated M-TAR-hardened staging,
  symlink drop, path-escape rejection, safety snapshot, commit to content
  history) - apply.
- `backup-list` (already returns `kind`/`scope`, so site packages are already
  distinguishable) and `backup-download` (works for any package) - list + fetch.

UI surfaces:

1. **Domains page - "Export site" per domain.** A button on each domain row
   (and a scope-checked one on the Configure panel) calls `site-backup-create`
   for that host, then links to the new package in the Packages view. Shown only
   when the user has `manage_domains` and scope to that domain's content root.

2. **Site Packages view** (a filtered section of the Backups page, or its own
   card). Lists `kind == 'site'` entries with source host (from the package
   manifest `site.json`), created time, size, and per-row actions:
   *Download*, *Apply*, *Delete*. Full/whole-docroot backups stay in their own
   section and are never offered to a scoped manager (they carry every client +
   secrets and remain a system-user operation).

3. **Upload a package.** A file control that posts to `site-backup-upload`
   (the first UI backup *upload*). Uploaded packages are marked provenance
   "uploaded" (the on-disk name already encodes it) so the operator can tell a
   locally-created package from an imported one.

4. **Apply flow.** Pick a package -> pick a target (a scope-visible registered
   domain, or *(default)* = the primary site) -> optional *clean* (wipe the
   target content root first) -> a confirmation that shows what will change
   (below) -> `site-backup-apply`. Destructive, so it stays POST + CSRF (it is
   already in `%MUTATING`) and takes the safety snapshot the API path already
   takes.

## Related features this process should carry

These are the pieces that make a hand-off trustworthy rather than a blind
overwrite; each is small and sits naturally in the same flow:

1. **Inspect before apply (manifest preview + dry-run).** Read `site.json` and
   show source host, theme, layout, nav mode, page/asset count and size before
   applying; and a dry-run summary - what content is added vs overwritten,
   whether the bundled layout/theme is missing on the target (installed) or
   present (left alone). No more applying a package sight-unseen.

2. **Snapshot + one-click rollback, at parity across surfaces.** The control-API
   apply snapshots the docroot and commits to content history; **MCP `site_apply`
   currently does not snapshot** (its own description says so). Align them - or
   surface the difference in the UI - and offer *Undo apply* that restores the
   pre-apply snapshot. Rollback is the safety net that makes apply low-anxiety.

3. **Target readiness check.** Fold the existing domain **Check** (DNS / vhost /
   TLS, and content_root exists) into the apply confirmation, so applying to a
   target whose DNS/TLS is not yet pointed is a visible warning, not a surprise
   after the fact. (DNS/TLS/vhost themselves stay the operator's/Hestia's job -
   out of scope, as in SM158.)

4. **Integrity on hand-off.** Publish a `sha256` next to each package (as the
   release tarball already does) so the receiving operator can verify a package
   that travelled between orgs was not altered in transit. Optional future:
   detached signing for tamper-evidence on cross-organisation hand-off.

5. **Presentation-key remap confirmation.** Apply rewrites the target domain's
   presentation keys (site_url, site_name, theme, layout, nav). Show which keys
   change and let the operator keep the target's own identity where wanted (e.g.
   migrate the content but keep the target's site_name), instead of silently
   adopting the source's.

6. **Retention / housekeeping.** Packages accumulate in the backups area; the
   Packages view needs *Delete* and a size/age display so a busy instance does
   not silently fill its disk (ties to the upload rate-limit already in place).

7. **Scope-respecting self-service.** The agency's delegated domain manager,
   confined by `dav_scopes` to their content root, sees *Export* only on their
   own domain(s) and *Apply* only to in-scope targets - the whole point of the
   client-facing hand-off. Enforced server-side already; the UI must mirror it
   (defence in depth + honest affordances).

## Permissions

- **Capability: `manage_domains`** (SM160), unchanged. Applying or exporting a
  package reconfigures a domain - it is domain management, **not** plain content
  editing. Do **not** loosen any of these to `manage_content`.
- **Plus scope.** Both create and apply enforce the `dav_scopes` union against
  the (source or target) content root on the MCP/API paths; the UI must only
  offer in-scope domains. A scoped manager cannot package a root they do not own
  or apply onto one they cannot reach.
- **Download stays gated the same as create.** A site package carries no secrets,
  but it does carry all of a domain's (possibly pre-launch, confidential)
  content - so download remains behind `manage_domains` + scope, not a weaker
  read.
- **Full backups remain system-only.** The whole-docroot `full` backup carries
  every client and the auth secrets; it is not self-service and must never appear
  in the scoped manager's Packages view. Keep the `kind: site` vs `kind: full`
  split sharp in the UI.

## Security implications

- **Upload is an ingress, already hardened.** `site-backup-upload` is rate-limited
  (`check_upload_rate`), forces the on-disk name (never trusts the client
  filename), stores raw and does **not** extract. Only *apply* extracts, and it
  does so in an isolated staging dir with the SEC-2026-07 M-TAR flags, dropping
  symlink members and rejecting any path that resolves outside the stage. SM183
  adds no new extraction path - it reuses this. Keep the size cap and rate limit;
  consider marking freshly-uploaded packages "unverified" until inspected.
- **Apply is destructive + reconfiguring.** It overwrites content (and with
  `clean`, wipes the target root first) and rewrites domain keys - so it must
  stay POST + CSRF (already in `%MUTATING`), take the safety snapshot, commit to
  content history, and require an explicit UI confirmation that names the target
  and the changes. The rollback (related feature 2) is the mitigation.
- **Scope confinement is server-enforced.** The UI is only a caller; the
  `dav_scopes` checks in the actions are the real boundary. The UI must not be
  the only thing hiding out-of-scope targets.
- **No-secrets / single-tenant invariant is the core safety property.** A package
  is exactly one domain's content, no other client, no secret, and SM158 prunes
  the shared layout to the one theme. SM183 must not widen this - and a test
  should assert a package still carries no `auth/`, no form keys, and no second
  domain's content, so the hand-off stays safe by construction.
- **Auditing.** create / upload / apply are already audited via the generic
  dispatch wrapper; the UI actions inherit it. Apply additionally lands in
  content history.
- **Storage / DoS.** Uploads plus accumulating packages consume disk; the
  rate-limit plus the new retention/delete (related feature 6) bound it.

## Doc nit to fix in passing

`action_site_backup_apply`'s header comment says *"Requires manage_content +
access"* - but the actual gate (both `%COOKIE_CAP` and `%need`, lines ~391/542)
is `manage_domains`. Correct the comment to `manage_domains` so it matches the
enforced capability (a `t/lint` cap-map test is the source of truth).

## Acceptance

- Domains page offers **Export site** per domain (scope-gated); the package
  appears in the Packages view, downloadable.
- The Packages view lists `kind == 'site'` packages (source host, time, size)
  with Download / Apply / Delete, and an Upload control; full backups never
  appear there for a scoped manager.
- **Symmetric round-trips both pass:** a package created by MCP `site_backup` is
  applied by a human in the UI; a package exported in the UI is applied by MCP
  `site_apply`. A test drives both directions.
- Apply shows a manifest/dry-run preview, warns on target-readiness, confirms the
  presentation-key changes, snapshots, and can be rolled back.
- A scoped domain manager sees Export/Apply only for in-scope domains; a
  `manage_content`-only user sees none of it.

## Out of scope / non-goals

- **Direct instance-to-instance push.** SM183 keeps the safe manual path
  (download -> carry -> upload). A network transfer between instances needs
  cross-instance authentication and is a separate, security-heavier proposal.
- **DNS, the web-server vhost/alias and TLS** for the target domain remain the
  operator's / Hestia's job - set them up first (the domain Check confirms them),
  then apply, exactly as in SM158.
