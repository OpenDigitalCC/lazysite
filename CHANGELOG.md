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

## 0.4.0 - Modular refactor, security hardening & conformance (QC review 2026-06-24)

Quality-control close-out audit for this milestone: **1416 tests green**;
`perlcritic` clean across every script and the new `Lazysite::*` modules; the
**strict SBOM gate passes** (180 components, `Exporter` declared for the new
modules); secrets gate clean; `tools/bench.pl --check` and
`tools/coverage.sh --check` floors hold.

- **Security** - seven-dimension review items 1-6 fixed: the control-API token
  path is no longer a manager operator (ACL-ownership bypass), the WebDAV
  blocklist applies to reads, `action_read`/`acl-*` enforce the full deny-set,
  account-create/add use `exists`, TOTP is replay-guarded, and single-use
  redemption is serialised by a consume lock.
- **Architecture (SM079)** - `lazysite-manager-api.pl` decomposed from 4286
  lines to a ~1240-line front-controller over 10 `Lazysite::*` modules
  (`Util`, `Auth::{Credential,Settings,Acl,Session}`,
  `Manager::{Common,Upload,Plugins,Files,Themes,Layouts,Artifact}`). The
  processor stays a standalone single file you can run against a folder.
- **Conformance** - curated `.perlcriticrc` gate, performance benchmark +
  baseline, committed secrets gate, five-audience docs taxonomy, `COPYRIGHT`,
  `bump-version.pl`; coverage is now measurable per-module (in-process module
  tests). `runtime_paths` perms corrected so a plain `install.pl` install is
  group-writable for www-data.

The detailed per-step log follows.

Refactor (SM079 step 2a) - Lazysite::Auth::Credential
: The credential primitives - the `/dev/urandom` CSPRNG, password and token
  hashing + verification, single-use secret verification, and token minting -
  move to `Lazysite::Auth::Credential`, removing the copies from `auth`, `dav`
  and the users tool. Unit-tested in-process (`t/unit/lib/02-credential.t`).

Refactor (SM079 step 1) - shared-module bootstrap + Lazysite::Util
: The modular scripts (auth, dav, manager-api, the users tool) now load shared
  helpers from `lib/Lazysite/` via a relative `use lib` bootstrap that resolves
  the module tree next to the script (run-in-place, tar, package and Hestia all
  just work, with the system `@INC` as the package fallback). The first module,
  `Lazysite::Util`, holds `log_event`, `const_eq` and the JSON log escaper -
  removing those copies from all four scripts. `lazysite-processor.pl` stays
  self-contained and depends on no module. `Util` is unit-tested in-process
  (`t/unit/lib/01-util.t`); it installs to `{DOCROOT}/../lib`.

Conformance (item 7, WP-2 / D2) - coverage instrumentation + regression floor
: The tests run the CGIs as subprocesses, which defeated `Devel::Cover` (it saw
  only the parent `prove` and reported `n/a`). `tools/coverage.sh` now
  instruments the children by exporting `PERL5OPT=-MDevel::Cover` so every
  spawned `perl` writes to one shared `cover_db` - a real coverage number for
  the first time. Measured: the core CGIs clear the 75% statement target
  (`dav` 92%, `users` 90%, `bundle-apply` 90%, `processor` 81%);
  `lazysite-manager-api.pl` is the gap at 60% (its 4273 lines - the same file
  flagged for a D1 split). A regression floor of 60% per cleanly-measured CGI
  is enforced by `tools/coverage.sh --check` (`dist/config/coverage-floor`),
  with 75% as the Commercial target. `auth.pl`/`install.pl`/plugins are split
  across tempdir copies (a measurement limitation, documented).

Fix - runtime directories were not group-writable on a plain install.pl install
: `install.pl` created `lazysite/auth` (and `cache`/`logs`/`manager/locks`/
  `layouts`/`lazysite-assets`) at non-group-writable modes on a fresh install:
  the file-install pass makes the directories first, so `create_runtime_paths`
  skipped them (its "don't touch an existing dir" guard, meant for upgrades). A
  plain (non-Hestia) install therefore reproduced the "add user: Permission
  denied" bug that the Hestia deploy only worked around by chmod-ing afterwards.
  The declared runtime modes (`auth` 2770, the rest 2775 - setgid +
  group-writable for the www-data CGI) are now applied on a **fresh** install
  even when the directory pre-exists; an **upgrade** still leaves an
  operator-tightened directory alone. Pinned by a new `03-install-pl.t` subtest.

Docs - five-audience documentation taxonomy + security-model refresh (item 7, WP-4)
: Adds the framework's audience entry points - `docs/USER.md`, `DEVELOPER.md`,
  `IMPLEMENTOR.md`, `OPERATOR.md`, `POLICY.md` - plus `COPYRIGHT`, and refreshes
  `docs/architecture/security.md` for the SM072-074 surfaces (claim/TOTP
  lifecycle, per-file ACLs, the forms carve-out), stating the Apache
  `X-Remote-*` trust-strip as a **hard** deployment requirement. `POLICY.md`
  records the Commercial regime and the CRA Art. 13 obligation status.

Conformance (seven-dimension review, item 7) - code quality, perf, hygiene
: D1: a curated Perl::Critic profile (`.perlcriticrc`, severity 4) enforced by
  `t/lint/02-perlcritic.t` with zero violations; the `return undef` convention
  is decided + documented and one real comma-statement was fixed. D3:
  `tools/bench.pl` - a host-relative benchmark (page render, token/password
  verify) with a committed baseline + a gross-regression gate (`--check`).
  D5/process: a committed secrets gate (`t/lint/03-secrets.t`);
  `tools/bump-version.pl` to roll the stale `VERSION`/`NEXT_VERSION`.


Security - review items 5 & 6 (TOTP/consume hardening + supply chain)
: TOTP codes are now **replay-protected** - a per-user `totp_last_step`
  rejects a code whose time-step was already accepted. Single-use redemption
  (claim / pairing key / recovery code / TOTP step) is **serialised by a
  scope-held flock** (`_consume_lock`), closing the read-verify-consume-write
  TOCTOU so the same secret can't be consumed twice under concurrency. The
  strict **SBOM gate passes** again (`Time::Local` was undeclared), and the
  stale `VERSION`/`NEXT_VERSION` (0.2.18) are bumped to the current line. The
  TOTP **seed-at-rest** item is accepted-risk (the verifier is the web tier),
  documented in the review.

Security - review fixes (priority 1-4 of the 2026-06-23 seven-dimension review)
: 1. The control-API **token path is no longer treated as a manager operator**
     (`_is_operator` returns 0 under token auth), so a `webdav` partner can no
     longer rewrite or clear another author's ACL ownership, and the token path
     never consults the client-influenceable `X-Remote-Groups`.
  2. The WebDAV blocklist now applies to **reads** as well as writes - an
     unscoped account can no longer `GET` `cgi-bin/*.pl` source.
  3. `action_read` and the `acl-*` actions enforce the full deny-set
     (`is_blocked_config`), so a manager can no longer read `forms/smtp.conf`'s
     plaintext password and ACLs cannot be set on system files.
  4. `account-create` / `add` use `exists`, not truthiness, so they can no
     longer clobber an existing passwordless account.
  Tests: `18-security-fixes.t` + F2 in `12-acl.t`. Full report in
  `docs/review/2026-06-23-seven-dimension-review.md`.

Ops - update every lazysite site at once
: A new `installers/hestia/lazysite-hestia-update-all.sh` discovers all
  lazysite sites on a Hestia host (by the `lazysite/.install-state.json`
  marker, so it never touches non-lazysite domains) and runs the per-site
  deploy on each from one release - `--list` previews, `--templates` also
  refreshes the shared vhost template. No more per-domain deploys.

Fix - the `.brief` deny was missing from the DEPLOYED vhost template
: The `.brief` `FilesMatch` deny had been added only to `lazysite.tpl` (the
  basic, no-auth variant), not `lazysite-app.tpl`/`.stpl` which the deploy
  actually applies - so on real sites `.brief` sidecars were still served raw
  by Apache (the processor 404 only covers non-existent paths). Added the deny
  to all four shipped templates, and `05-brief-sidecar.t` now checks every one,
  not just `lazysite.tpl`. Re-apply the template (deploy with `--templates`) to
  pick it up on existing sites. Also corrected the runbook, which told you to
  install the basic template as `lazysite-app`.

Docs - authoring guides updated from a real build (partner feedback)
: The layouts briefing now states the deploy model plainly - **activate the
  theme globally, keep pages layout-agnostic**, and a per-page `layout:` is a
  preview tool you remove after activating - and corrects activation to
  **self-serve** (`theme-activate` / `layout-activate` over the control API),
  not an operator hand-off. The authoring briefing gains the embedded-HTML
  rules (4-space indent becomes a code block; blank lines wrap in `<p>`; keep
  HTML flush and contiguous, or use a `.md` partial) and the
  multi-line-include requirement.

Forms - an agent can wire a form over WebDAV
: A per-form dispatch config `lazysite/forms/<name>.conf` is now agent-editable
  over WebDAV with `manage_config` - it only names operator-defined handlers,
  no secrets. So a publishing agent deploys an enquiry/contact form to file
  storage itself (`local-storage` ships by default), with no operator step.
  The secret files (`smtp.conf`, `handlers.conf`) and the `submissions/` store
  stay denied, and email delivery still needs operator-configured SMTP. The
  canonical deny list (dav, well-known, brief, whoami) now names those specific
  files instead of all of `lazysite/forms/`, pinned by `06-deny-consistency.t`;
  the publishing brief gains a "Wiring a form" task.

Docs - `.brief` guidance is now a full spec template
: The publishing briefing spells out what a good brief contains (purpose,
  sections in order, tone & style, images & sources, constraints, a "To
  change this page…" line, and the append-only log), with a worked example;
  the authoring briefing's page-creation steps now include writing the brief
  and point to it. So any agent produces briefs rich enough for the
  edit-the-brief → refactor-the-page loop.

Fix - `whoami` reported a stale `scope.deny`
: `whoami` listed only `/lazysite/forms/.smtp-password` as denied while the
  dav denies all of `/lazysite/forms/` (and `/cgi-bin/`, `/manager/`,
  templates) - so an agent trusting `whoami` thought it could write form
  configs it cannot. `whoami` now reports the canonical deny set, and
  `06-deny-consistency.t` pins it alongside the well-known and brief.

Control API - `config-set` wired
: A token client with `manage_config` can now set an allowlisted site-config
  key (`site_name`, `site_url`, `search_default`) in `lazysite.conf` over the
  control API - previously the action was in the capability allowlist but had
  no dispatch handler ("not available to token clients"). Privilege-relevant
  keys (manager groups, plugins, auth) and ones with dedicated actions
  (layout/theme) are refused. So a publishing agent can set its own site name
  without operator hand-editing.

Fix - operator could not manage accounts it did not personally create
: "Generate setup link" (and the other account actions) failed with "Not
  authorised to manage 'X'" for a manager-group operator: every named actor
  was confined to its own `managed_by` sub-tree, and a top-level account is
  created with `add`, which stamps no sub-tree at all. A manager-group
  operator (like `local`) is now unrestricted and may manage any account; a
  delegated sub-manager stays confined to its own tree.

Manager Users card
: The Add-user form drops the optional password box - accounts are created
  with no password and credentials are set afterward from the card (Generate
  setup link, or Generate credential), removing the duplication.

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
  exact parameters. A new `06-deny-consistency.t` pins the
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
