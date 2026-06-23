---
title: "lazysite - Changelog"
subtitle: "Release history, newest first. Tags are the stable identifiers."
brand: plain
standard-margins: true
---

## About this changelog

Versioning
: Releases are git tags (`vX.Y.Z`). Since SM063, `main` is unstable and
  carries unreleased work; a release is a tag cut from a commit on `main`,
  with no per-release version-bump commit.

Keying
: Entries are high-level. Released versions are keyed by tag; unreleased
  entries are keyed by SM number and short commit ref.

## Unreleased

Manager - WebDAV publishing toggle
: `webdav_enabled` is now a first-class Config-page setting (WebDAV
  publishing: enabled / disabled) and a documented commented entry in the
  shipped `lazysite.conf`, instead of an undocumented hand-edit-only key.
  (The dav still 404s every method until it is on - that is its deliberate
  "feature off = the endpoint does not exist" gate.) The publishing briefing
  gains an "If `/dav` does not respond" section so an agent reads that 404 as
  "WebDAV disabled", not "wrong path", and knows the next 403/401 gates.

Fix - www-data manager could not write the auth store
: The auth files the CLI tool and the web manager both manage (`users`,
  `groups`, `user-settings.json`) were written `0640`/`0644` - owner-write
  only - so after a CLI write (e.g. the post-deploy `passwd manager`) the
  www-data CGI (no suexec) could not edit them: "Permission denied" on
  add-user. Now written `0660` (group-writable; the auth dir is `02770`, so
  no world access), and the users tool creates the auth dir `02770` to match
  what the deploy sets.

Manager Users card
: The Access section's lone "Interactive login" checkbox is now a Human / AI
  type switch (the `ui` setting), matching the Add-user form; the "Create
  under" default option is relabelled to make clear it creates the account
  directly under you, the manager.

Docs + consistency follow-ups
: The publishing briefing's control-API section now documents each action's
  exact parameters (and notes `config-set` is gated but not yet wired - use
  the manager Config page meanwhile). A new `06-deny-consistency.t` pins the
  `.well-known` and onboarding-brief deny lists to one canonical set and
  checks the dav backs them, so the three can no longer drift apart.

SM074 - Per-file ownership and ACLs
: An opt-in entry in a central store (`lazysite/auth/acls.json`: `owner` +
  `read`/`write` allowlists) narrows access within a shared WebDAV scope -
  others can no longer overwrite a page you own, and a `read` list hides the
  source from other authors. ACLs are metadata, not content, so they live in
  one file (no per-file sidecars cluttering the tree) and are managed through
  `acl-set` / `acl-get` / `acl-remove` (manager + token control API, the
  latter gated on `webdav`). Enforced in `lazysite-dav.pl` (read + write) and
  the manager API (operators bypass; owners pass). The store sits in the
  write-denied `lazysite/` tree, so a raw `PUT` can never touch it. No entry
  means unchanged scope-only behaviour. The Files page shows a file's owner.
  Usernames only in v1 (groups deferred).

Lock propagation fix
: A WebDAV lock (or another manager user's lock) now blocks a manager
  *save*, not just opening the editor - `action_save` was parsing the shared
  lock record with the legacy line format and silently ignoring JSON/DAV
  locks.

SM073 - Per-file `.brief` sidecars
: Every authored file gets a sibling `<file>.brief` recording its intent and
  an append-only edit log. Briefs are writable over WebDAV and editable in
  the manager, but never served publicly (Apache `FilesMatch`, the dev
  server, and the processor all deny them) and never indexed in `sitemap.xml`
  / `llms.txt`. Encouraged, not enforced. The manager Files page flags each
  file's brief (present / missing, with one-click create) and is editable
  there.

Files page - list by type (SM072 §13 roadmap)
: The manager Files page gains a type filter - by extension, by folder, or
  "Generated HTML" (an `.html` with a `.md`/`.url` source beside it) - so an
  operator can quickly isolate and selectively delete stale cached pages
  after content moves or theme changes. `action=list` now returns per-file
  `ext`, `generated`, `has_brief` / `is_brief` metadata.

SM072 - Self-service credentials, claim links, and account expiry
: The operator sets account parameters; the user provisions their own
  secret. Batch 1: the claim-token primitive - a single-use, short-lived,
  hashed claim the holder redeems to set their own password or mint their
  own token (the operator never sees it). `Generate setup link` and
  `Reset credential` (revoke + fresh claim) on the Users card; a public
  `/claim` page (`auth.pl`, rate-limited, HTTPS-only, one generic error
  with no account enumeration). Plus per-account `expires_at` for
  time-boxed access ("one day, then auto-expire"), enforced at login and
  on credential verification. Also a fourth AI briefing,
  `ai-briefing-publishing`, documenting the agreed WebDAV-for-files /
  control-API-for-config publishing model. Design of record: SM072 spec.
  Batch 3: the token lifecycle over HTTP - `?action=exchange` (pairing key
  -> access token) and `?action=rotate`, both returning `{token,
  expires_at}` (one live credential). Batch 4: TOTP MFA (RFC 6238,
  self-contained) - enrol on the card (secret + otpauth URI + 8 single-use
  recovery codes), a login second factor, gated per account. Also: account
  Type (Human/AI) at creation with the type shown in the list; account
  rename across all stores; agent-editable `lazysite/nav.conf` over WebDAV
  (manage_config). Also shipped from the roadmap: the machine-readable
  bootstrap (per-partner brief block + `/.well-known/ai-partner`); manager
  version display; agent introspection (`whoami` over the control API -
  capabilities, groups, scope, plugins, layouts/themes, site capabilities);
  plugins publish `provides` (form-smtp -> email-send) for detection; email
  set-password / forgot-password (gated on SMTP + the email capability,
  generic responses); and an audit-log UI (state-changing POSTs to
  `lazysite/logs/audit.log`, a `/manager/audit` page with a per-user
  filter). The contact-form 404 (stale `lazysite-form-handler.pl` action
  name) is fixed. Still roadmap: editor<->WebDAV lock propagation and the
  offline publish bundle.

SM071 - WebDAV theme and layout management
: Staged authoring of themes and layouts with a safe back-out, in three
  phases. Phase 1: session-scoped, signed-cookie preview of an inactive
  layout/theme (never cached, never leaked). Phase 2: a delegated sub-user
  account model - provenance (`created_by`/`managed_by`), the
  `create_sub_users` / `delegate_sub_user_creation` permissions,
  disable/enable/cascade/reassign on ancestry, the `manage_themes` /
  `manage_layouts` / `manage_config` capabilities, a pairing-key → rotating
  access-token lifecycle, and `partner-create` with an onboarding brief.
  Phase 3: per-object WebDAV authoring of `lazysite/layouts/**` (active
  read-only), an `lzs:sha256` content-hash manifest, a token-authenticated
  control API (capability-gated, CSRF-exempt), activate-with-backup
  (validation, base-manifest 409, artifact lock, retention) for themes and
  layouts, and a per-token rate limit with a `Retry-After` retry contract.
  See `docs/feature-requests/SM071-webdav-theme-layout-management.md`.

SM070 - WebDAV publishing endpoint (`8687562`)
: RFC 4918 class 1 + 2 `/dav` endpoint, authenticated with HTTP Basic over
  TLS against the existing user database, with per-user access mechanisms,
  generated credentials, and a lock store shared with the manager editor.

## Releases

```datatable
columns: Version | Date | Highlights
widths: 2.6cm | 2.6cm | X
bold: 1
tone: medium
---
0.3.1 | 2026-06-12 | Maintenance tag; no source changes over 0.3.0.
0.3.0 | 2026-04-23 | Release tooling split into commit.sh + release.sh (SM063) with next-patch proposal (SM064); SBOM and manifest no longer tracked, generated fresh per release (SM065); manager UI polish (SM066); theme-install flow coherence (SM068); admin-bar theme switcher removed (SM069).
0.2.0 – 0.2.19 | 2026-04-22 – 2026-04-23 | Hardening and manager maturation across nineteen point releases: structured logging, the manager Config and Files apps, CSRF gate keyed by HTTP method, rotate-auth-secret for mass logout, login rate limiting, the journey test tier, and the D013 layouts/themes directory reshape.
0.1.0 | 2026-04-21 | Initial release: the Markdown-to-HTML processor (Template Toolkit layouts, themes, and the scan / include / oembed directives), built-in and reverse-proxy authentication, forms with an SMTP helper, the web manager (file browser, editor, plugins), an x402 payment-protocol demo, the local dev server, and the Test::More suite.
```
