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
