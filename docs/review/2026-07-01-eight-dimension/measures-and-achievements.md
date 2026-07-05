---
title: "lazysite - Non-functional measures and achievements"
subtitle: "Eight-dimension state of record, as of v0.6.0"
brand: plain
standard-margins: true
---

## Purpose

This document is an up-to-date, factual summary of the non-functional measures in
place across lazysite, organised by the eight review dimensions. It describes what
has been achieved: the mechanisms, gates, controls and specific figures that exist
in the codebase and its release process as of version 0.6.0. It draws on the
eight-dimension review conducted at v0.5.35 (2026-07-01) and on the work delivered
in the releases since (0.5.36 through 0.6.0).

## Method of assessment

The measures below are organised by the eight-dimension non-functional framework
defined in the shared toolchain, assessed in signoff order against lazysite's
declared regime.

Regime
: lazysite declares the **Commercial** regime in `docs/POLICY.md`. The
  per-dimension assessment criteria are those the framework keys to that regime.

Dimensions (signoff order)
: 1 Correctness and groundedness, 2 Code quality, 3 Test coverage, 4 Performance,
  5 Reliability and resilience, 6 Security, 7 Documentation, 8 Policy compliance.

Original review
: the point-in-time review at v0.5.35 (commit de12238) was run manually by four
  independent assessors, each covering a dimension pair and writing a standalone
  report in this directory. Every mechanical gate was executed at the pinned tag,
  and findings cited command output and file:line evidence. The individual reports
  (`dimension-1-correctness.md` … `dimension-8-policy.md`) remain the detailed
  record of that snapshot; this summary reflects the current state.

Evidence basis for this summary
: the figures cite the current tree at v0.6.0 - the full suite, the coverage
  floors in `dist/config/coverage-floor`, the lint profiles, the release script,
  and the shipped documentation set - together with the CHANGELOG record of what
  each release delivered.

## The eight dimensions - measures achieved

### 1. Correctness and groundedness

Compile integrity
: every production Perl file compiles under `perl -c`. This is enforced as a
  committed gate, `t/lint/04-compile.t` (a compile sweep of all scripts and
  modules), so a non-compiling file cannot pass the suite.

Canonical capability resolver
: `Lazysite::Auth::Settings::caps_for` is the source-of-truth reader for account
  capabilities, with the `groups_grant_cap` helper beside it; the effective-settings
  path resolves through it. The login-landing path's separate private copy was
  removed and routed through the shared helper. The processor keeps a deliberate
  module-free copy on the render hot path, recorded in
  `docs/adr/0001-capability-resolution.md`.

Encoding consistency
: JSON authentication files are read as raw octets for `decode_json` everywhere,
  a single settled convention (recorded in ADR 0001), with a regression test
  guarding the non-ASCII case.

Path safety
: every filesystem path derived from request input passes through
  `Cwd::realpath` and is verified to start with `$DOCROOT` before any file
  operation, applied consistently in the processor and the manager API
  (`docs/architecture/code-quality.md`).

Grounded features
: shipped features are exercised by the test suite (see Dimension 3); plugin
  discovery is honest, with each discovered script answering `--describe`.

### 2. Code quality

Static analysis gate
: Perl::Critic is enforced at **severity 3** with zero violations, via
  `t/lint/02-perlcritic.t` against the project profile `.perlcriticrc`. A separate
  security-themed pass runs at severity 1 (`t/lint/05-perlcritic-security.t`, also
  zero). Deliberate deviations (for example `return undef` as the project idiom,
  and `RequireExtendedFormatting` applied above a 60-character complexity
  threshold) are each documented with a rationale in `.perlcriticrc` and
  `docs/architecture/code-quality.md`.

Formatting gate
: `.perltidyrc` is calibrated to the hand-written house style. A changed-code-only
  formatting gate (`tools/tidy-check.pl` / `t/lint/06-tidy.t`) requires new and
  edited lines to match it, without reformatting the existing tree.

Additional lint gates
: `t/lint/01-stale-paths.t` (path/name currency) and `t/lint/03-secrets.t`
  (no hardcoded private keys, cloud key ids, or assigned secret literals in
  tracked source) run in the same suite.

Structure
: functional Perl throughout (no object orientation, no `bless`), `use strict;
  use warnings;` in every script, and a shared `lib/Lazysite/` module tree of
  eighteen modules where common logic lives once, consulted by the CGIs.

### 3. Test coverage

Suite size and taxonomy
: the full suite is **154 files and 2,365 tests** (green at v0.6.0), organised in
  a five-level taxonomy under `t/`: `unit/`, `integration/`, `journey/`, `smoke/`,
  and `lint/`, plus `tools/`. The CGIs are exercised as real subprocesses with a
  CGI environment, or in-process through a `LOAD_ONLY` hook; `t/lib/TestHelper.pm`
  provides the fixtures.

Coverage floors
: `dist/config/coverage-floor` declares a statement floor of 60 and a branch floor
  of 60, with a per-file branch override for `lazysite-manager-api.pl` (also 60)
  and a target of 75.

Coverage enforced at release
: `tools/coverage.sh --check` runs (instrumented) as part of `tools/release.sh`,
  so a coverage breach blocks a release rather than being a hand-run check.

### 4. Performance

Benchmark harness and gate
: `tools/bench.pl --check` times three operations against a recorded baseline in
  `dist/config/bench-baseline.json` and passes when all are within tolerance. The
  gate runs in a few seconds and is executed as part of `tools/release.sh`.

Split render measurement
: the render benchmark is split into a cache-hit path and a render-miss path, so
  the timed figure is not silently the cache-hit case; the baseline records host,
  Perl version and capture date for provenance, and the tolerance was tightened to
  2x.

Measured properties on record
: token verification is materially cheaper than password verification (recorded
  ratios in the baseline). `docs/architecture/performance.md` records a per-CGI
  module-load floor of roughly 50 ms and a concurrency speedup on cache-hit
  requests.

Caching design
: the processor writes an `.html` cache next to each source `.md`; subsequent
  requests serve the cached file verbatim, regenerating on miss. Historical
  optimisation is recorded (for example the collapse of three manager CGI calls
  into a single `users-page` endpoint to cut cold-start cost).

### 5. Reliability and resilience

Backup and restore
: `install.pl` provides `--restore`, `--restore --backup PATH`, and
  `--list-backups`; pre-upgrade backups accumulate under
  `{docroot}/lazysite/backups/` and are pruned per `backup_retention`. Content
  snapshots (`lib/Lazysite/Manager/Backups.pm`) support content and full-system
  scopes; in-manager restore takes a prerestore safety snapshot first and clears
  affected caches. A full-system backup, restored by
  `install.pl --restore-full … --domain …`, supports cross-domain migration.
  The restore round trip is covered by `t/tools/03-install-pl.t` and
  `t/unit/manager/22-backup-restore.t`.

Fail-closed writes
: manager write paths and the form-handler append check for the
  out-of-space/quota case and unlink half-written files on failure; disk-full
  injection and concurrent-writer races are covered by
  `t/integration/13-write-failure.t`. WebDAV PUT bodies are streamed in bounded
  chunks.

Concurrency and locking
: theme/layout activation snapshots under an artifact-level lock across
  validate-snapshot-flip; WebDAV returns 423 for a foreign lock, with a documented
  423/429 retry contract, covered by the DAV lock and rate-limit tests.

Rate limiting
: login attempts are rate-limited per IP in a sliding window, boundary-tested in
  `t/unit/auth/03-login-rate-limit.t`.

Graceful degradation
: an unparseable `user-settings.json` logs a warning and falls back to defaults
  rather than failing management; the audit reader is rotation- and
  truncation-aware.

Operational tooling
: `tools/lazysite-check.pl` reports per-check OK/WARN/FAIL with remediation hints,
  offers `--fix` for safe permission repairs, and `--check-dav` to verify the DAV
  endpoint responds correctly; a weekly `logrotate` snippet ships under
  `installers/hestia/`.

### 6. Security

Threat model
: `docs/SECURITY.md` is a **STRIDE** threat model with control verification framed
  against **OWASP ASVS L1**. It enumerates the assets (hashed passwords, `lzs_`
  tokens, TOTP seeds, session cookies, content, form submissions, the per-install
  HMAC secret, the audit trail) and five trust boundaries, and pairs each STRIDE
  category with its control.

```datatable
columns: STRIDE category | Control in place
widths: 4.6cm | X
bold: 1
tone: medium
text: 2
---
Spoofing | Two-signal trust gate (`apply_trust_gate`) with mandatory edge stripping of client-supplied `X-Remote-*` headers (shipped vhost template); HMAC-signed session cookie.
Tampering | Template Toolkit runs with `EVAL_PERL=0`; layout authoring gated by `manage_layouts` + `webdav`; content-vs-layout capability split (SM082).
Repudiation | Append-only audit trail (who / what / target / origin / outcome, including denied attempts); audit read gated by the `audit` capability.
Information disclosure | Secrets under `lazysite/auth/` (server-denied, mode 0660); stats export aggregated and IP-anonymised; error surface synthesised.
Denial of service | Per-IP login rate limiting; upload size gate; bounded-chunk PUT streaming; fail-closed writes; the SM128 bad-URL auto-blocker (on by default).
Elevation of privilege | Token clients confined to the control-API subset via the `%need` capability map, never operators; per-file ACLs (SM074); manager bypass is cookie-only; SM127 manager/remote separation.
```

Capability model
: capabilities are groups-only and explicit, resolved through one path and
  recorded in `docs/adr/0003-channel-action-capability-model.md`; per-file ACLs
  bind partner writes; manager writes carry an HMAC CSRF token.

SSRF guard
: `lib/Lazysite/Fetch.pm` `is_safe_url` is the single guard for outbound fetches;
  it rejects loopback, RFC1918, link-local/metadata, IPv6 loopback and link-local,
  multicast and CGNAT ranges, and logs the refusal.

Bad-URL auto-blocker (SM128, on by default)
: `lib/Lazysite/BadUrl.pm` counts scanner-probe hits per source IP in a rolling
  window and blocks at a threshold (default 10 hits / 3600 s), with a bounded
  block store and a cheap fast path when nothing is blocked. Enforcement is in the
  auth wrapper (`_bad_url_guard`); auto-blocks are audited.

Manager/remote separation (SM127)
: an account holding interactive manager access (`manager_ui`) is refused on the
  API and MCP transports, in both `lazysite-manager-api.pl` and `lazysite-mcp.pl`,
  and a group may not combine `ui` with a remote (`api`/`mcp`) channel.

Transport channel gating
: the control-API token path requires the `api` capability and the MCP session the
  `mcp` capability before dispatch; introspection remains open.

Mechanical gates
: the secrets lint, the strict SBOM gate (an undeclared `use`/`require` fails the
  release), and the security-themed Perl::Critic pass all run green in the suite
  and release path.

Vulnerability disclosure
: the repository-root `SECURITY.md` is the coordinated-vulnerability-disclosure
  policy (reporting channel, scope, and response targets).

### 7. Documentation

Audience doc set
: the core set is present and role-scoped - `docs/USER.md`, `docs/DEVELOPER.md`,
  `docs/IMPLEMENTOR.md`, `docs/OPERATOR.md`, `docs/POLICY.md`, `docs/FEATURES.md`,
  `docs/SECURITY.md`, and `docs/ACCESSIBILITY.md` - alongside `README.md`,
  `UPGRADE.md`, and the root `SECURITY.md`.

Architecture and decision records
: `docs/architecture/` holds the security, code-quality and performance
  descriptions; `docs/adr/` holds six records (`0001` capability resolution,
  `0002` uncommitted-tree release contract, `0003` channel x action capability
  model, `0004` install classification and provenance, `0005` release channels,
  `0006` raw-mode for artifacts only).

Generated, drift-checked references
: `docs/reference/capability-map.md` and `docs/reference/quickstarts.md` are
  generated from the `Lazysite::Capabilities` builder (single source of truth,
  golden-tested against drift); `docs/reference/host-dependencies.md` is generated
  from `dist/config/sbom-deps.json`. CLI tools carry POD, from which
  `tools/gen-manpages.pl` renders man pages at release.

Accessibility
: `docs/ACCESSIBILITY.md` is a WCAG 2.1 AA self-assessment of the manager UI and
  default theme.

Shipped user reference
: the `starter/docs/` set ships inside every installation as the canonical
  user-facing reference, including AI briefings and feature guides.

CHANGELOG discipline
: `CHANGELOG.md` keys released versions by git tag and unreleased entries by SM
  number plus commit reference, newest-first with dated headings - one source of
  truth for what changed.

### 8. Policy compliance

Regime and posture of record
: `docs/POLICY.md` declares the Commercial regime, carries an honest-declaration
  disclaimer, and structures the record around regime, licensing and supply chain,
  the CRA Article 13 status table, support period, and data protection. The CRA is
  cited as Regulation (EU) 2024/2847, and the 11 December 2027 CE-marking date is
  tracked.

Software bill of materials
: each release tarball contains `sbom.json` in CycloneDX format with per-component
  SHA-256 hashes and SPDX licence ids, generated by `manifest-to-sbom.pl --strict`
  from a per-file manifest; the strict gate refuses the release if code imports an
  undeclared module, so the SBOM cannot drift from the code.

Security-update mechanism
: the edge/stable release channels (`tools/release.sh`, with `--final` marking
  stable) and the per-site `update_channel` honoured by the Hestia updater provide
  a documented update path; `UPGRADE.md` records the behaviour.

Install classification and provenance
: `dist/config/classification.json` classifies every shipped file as code
  (overwritten on upgrade) or seed (operator content, preserved); a provenance
  stamp distinguishes lazysite content from operator content (recorded as
  ADR 0004).

Licensing
: `LICENSE` and `docs/POLICY.md` state MIT; the SBOM carries per-component SPDX
  licence ids.

## Delivery record since the review

The releases from 0.5.36 to 0.6.0 delivered the following, by theme.

```datatable
columns: Release | Delivered
widths: 2.4cm | X
bold: 1
tone: light
text: 2
---
0.5.36 | Shared `groups_grant_cap` resolver + octet-encoding settled (D1); compile-sweep and security-perlcritic lint gates added; `release.sh` wired to run `bench.pl --check` and `coverage.sh --check`; branch coverage floor added and `lazysite-auth.pl` joined the gate; render benchmark split into cache-hit vs miss with provenance.
0.5.37 | Fail-closed cache and form-append writes with a disk-full/concurrent-writer test; in-manager backup restore with safety snapshot (SM084); ADRs 0002-0006; `docs/SECURITY.md` STRIDE + ASVS L1 threat model; SM095 documentation currency sweep; CRA citation corrected to 2024/2847.
0.5.38 | Reported-issue fixes: dev-server repeated-header handling (RI-001) and named WebDAV denial reasons with an `X-Lazysite-Deny-Reason` header (RI-002), each with a test.
0.5.39 | Agent capability discovery (`describe_capabilities` / `describe-capabilities`) built from `@CAP_KEYS`, generating `capability-map.md` + `quickstarts.md`; strict api/mcp transport gating; generated host-dependency doc + `lazysite-check.pl --dependencies`; capability-drift fix.
0.5.40 | Perl::Critic raised to severity 3 with zero violations; changed-code perltidy gate (`.perltidyrc`, `tools/tidy-check.pl`, `t/lint/06-tidy.t`); `docs/ACCESSIBILITY.md` (WCAG 2.1 AA); POD + man-page generation.
0.5.41 | Bad-URL auto-blocker (SM128, on by default); manager/remote separation (SM127); Duplicate-a-page and Migrate-to-local (via the shared `Lazysite::Fetch` SSRF guard, SM096); manager settings reorganisation; `install.pl --channel` and `--force`.
0.6.0 | Stability milestone marking the settled feature set; no code change from 0.5.41; all gates green.
```

Test-suite trajectory: the review baseline was 139 files / 2,003 tests at v0.5.35;
the suite stands at 154 files / 2,365 tests at v0.6.0.

## Current gate and metric snapshot

```datatable
columns: Measure | State at v0.6.0
widths: 6cm | X
bold: 1
tone: medium
text: 2
---
Full test suite | 154 files, 2,365 tests, green
Compile sweep | `t/lint/04-compile.t`, all production files
Perl::Critic | Severity 3, zero violations; security theme severity 1, zero
Formatting | `.perltidyrc` house profile, changed-code gate `t/lint/06-tidy.t`
Secrets lint | `t/lint/03-secrets.t`, clean
Coverage floors | Statement 60, branch 60 (target 75), enforced in `release.sh`
Benchmark gate | `bench.pl --check`, three ops within 2x tolerance, enforced in `release.sh`
SBOM | CycloneDX per-release, strict gate (undeclared import fails the release)
ADRs | Six records under `docs/adr/`
Threat model | STRIDE + ASVS L1 in `docs/SECURITY.md`
Capability docs | Generated map + quickstarts, drift-tested
Regime | Commercial (`docs/POLICY.md`), MIT licensed
```
