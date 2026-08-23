---
title: "SM410: the typed data layer - audit and consolidated plan"
subtitle: "The two inbox briefs (data plugin + full-screen data manager) audited against the tree: every 'CC confirms' marker resolved, two spec claims corrected before they could become rework, and the fifteen sub-SMs consolidated into one dependency-ordered map. Implementation starts post-stable; SM409 and the session-module extraction go first."
brand: plain
standard-margins: true
status: candidate
status-note: "DP-6 SCOPE DECIDED 2026-08-22: a site package carries the typed-JSON export OPT-IN PER PACKAGE, not always. This corrects the spec's 'typed-JSON in site_backup AND site packages' in one direction: backups carry data, packages carry it only when the operator asks. THE REASON IS PRIVACY, not cost - a package is a portable hand-over artefact, and shipping table contents by default means handing a third party whatever an operator put in a directory or a contact table. Rejected: always-on (matches the spec, hands over data by accident), the raw SQLite file (exact but cannot cross engines and is not reviewable before handover) and backups-only (cleanest privacy story, leaves a migrated site to move its data by hand). AUDIT COMPLETE 2026-08-19; implementation deliberately NOT started - the release manager's sequencing is plan now, build after the next stable, with the data plugin built as ADR 0009's first conforming implementation. The briefs are archived at inbox/archive/2026-08-19-data-{plugin,manager}.md and remain the detailed spec; this filing carries the audit deltas and the map, not a retype. TWO SPEC CLAIMS CORRECTED: (1) 'site_backup already captures the SQLite store - done by construction' is true only for FULL backups. Content backups exclude ./lazysite entirely, and a site package copies content/nav/layout only - so a migrated or content-restored site would silently arrive without its database. Backup/package participation moves from DP-6 nice-to-have to a DP-6 requirement with an apply-side restore. (2) 'CSRF per the existing manager-api pattern' assumes an identity the endpoint would not have: lazysite-data.pl matches the front door's lazysite-*.pl route but only processor and manager-api are wrapped, so the endpoint would see X-Remote-User exactly as the client sent it - the SM402 defect reintroduced on a new surface. Resolution: extract session verification from lazysite-auth.pl into Lazysite::Auth::Session (SM402's own option 2, closing that filing's open item) and the endpoint self-validates the cookie; no template churn, and robust against the stale-fleet-template failure mode SM374 measured. ALL CC-CONFIRMS RESOLVED - see the register in the body. Supersedes the BACKLOG.md 'Database plugin' sketch (per-visitor schemas named there - session, profile, basket - are exactly what the settled boundary excludes)."
---

# What this is

The audit the two briefs asked for, plus the consolidated build map. The briefs
are the spec; this records where the tree said otherwise and every decision the
briefs deferred to audit. Read the briefs first for the design; read this for
what changed.

# Corrected claim 1: backup is not done by construction

The plugin brief: *"SQLite: the store is a file in the tree; site_backup
already captures it. Done by construction."*

Measured: **content** backups run tar with `--exclude=./lazysite`, and a
**site package** stages `content/`, `nav`, `layout/` only
(`SitePackage.pm`). Only **full** backups carry `lazysite/db/`. So the two
artefacts an operator actually uses to move or restore a site would silently
drop the database - the worst possible shape, because everything else arrives
and the site looks migrated.

Consequence: DP-6 (backup/portability) gains a site-package `data/` member
carrying the typed-JSON export, an apply-side restore, and a content-backup
posture decision - and its cross-engine test gains a "package a site, apply it
elsewhere, rows survive" case. Under ADR 0009 this is the `owns.storage`
declaration doing its job.

# Corrected claim 2: the endpoint's identity does not exist yet

The brief: inline writes enforce CSRF *"per the existing manager-api pattern"*
and gate on the authenticated user's groups. The manager-api's identity comes
from the auth wrapper - and the front door wraps only
`lazysite-processor.pl` and `lazysite-manager-api.pl`. A new
`lazysite-data.pl` would be routed and NOT wrapped: `HTTP_X_REMOTE_USER`
reaches it exactly as the client sent it. This is the defect SM402 removed
from the form handler, reintroduced by spec on a new surface.

Resolution, and it closes an open item rather than adding one: **extract
session verification from `lazysite-auth.pl` into `Lazysite::Auth::Session`**
- SM402's own recorded option 2 - and the data endpoint self-validates the
cookie. Chosen over wrapping the endpoint because wrapping needs the fuller
vhost templates edited across the fleet, and SM374 measured exactly how that
fails: a stale template makes the fix indistinguishable from the bug. A
self-validating endpoint works identically on every deployment shape,
including one-rule and stale-template hosts. `lazysite-auth.pl` becomes the
extraction's second caller, with the behaviour-comparing drift test the house
uses when a fact must exist twice (t/lint/60 pattern) unnecessary - it is one
module with two callers, not two copies.

# The CC-confirms register - every deferred decision, resolved

Descriptor file format
: YAML approved by the release manager (2026-08-19). **YAML::PP**, safe-load
  only (no tags, no objects), over YAML::XS: pure Perl fits the SBOM posture,
  descriptor files are small so speed is irrelevant, and both are present on
  the reference host (YAML::PP 0.39, packaged as libyaml-pp-perl). First YAML
  dependency in the tree; sbom-deps.json entry with debian/rhel/alpine names
  per release-workflow rules.

Config keys
: `db_enabled` / `db_source` / `db_source_file` confirmed against convention -
  the `*_file` secret indirection has a live precedent (form-smtp's
  `password_file`), and "accepts but never displays" matches the existing
  write-only store treatment.

The `anyone` sentinel (anonymous inline writes)
: **Dropped from v1 entirely.** No existing sentinel to align with
  (`auth_default` and `auth_groups` govern reads), and an anonymous
  browser-write surface is a spam/abuse surface the forms path already covers
  with rate limits, honeypot and quarantine. Default posture
  (authenticated-only) becomes the only posture until a real site needs
  otherwise; revisit with cause.

F0012 (pagination dependency)
: Dangling reference - no F0012 exists in this repo; it is the design
  sessions' own numbering. The mechanism it means is the front-matter
  `query_params:` declaration, which exists. The briefs' own remedy stands:
  v1 bindings are limit-only, no offset parameter, and the manager grid
  paginates via manager-api internally (the DM brief already notes it does
  not wait).

Field descriptors as "a shared convention" with forms
: True at the SEMANTIC layer only, and the docs must say so. Forms use an
  inline token grammar (`required select:A,B` - just extended by SM401);
  descriptors are structured YAML. The shared convention is the **type set
  and validation rules**, not the surface syntax: the DP-4 forms "db" handler
  validates submissions against table descriptors server-side, and `:::form`
  syntax does not change. Writing "one grammar" into docs as if syntax were
  shared would be a false claim of the SM388 class.

Doc placement
: Data-driven content section joins ai-briefing-building-sites (the three
  sources - inline files, `url:`, `db:` - are one idiom there already);
  descriptor reference stands alone as the shared-convention document.

Multi-site
: v1 tables are site-global, confirmed compatible with the SM151 direction;
  if tables become per-domain the confinement point is `dav_scopes` at
  dispatch exactly as the file actions do it. Recorded, not built.

Endpoint conventions (post-date the briefs)
: The endpoint inherits SM388 conditional GET (weak ETag, 304), SM389/SM396
  bounded body reads with the declared-length refusal-before-allocation, and
  SM404's checked atomic writer for `.schema-state.json`. None of these
  existed when the briefs were drafted; all now do, so DP-3 consumes rather
  than reinvents them.

Serialiser hoist
: The manager brief's recommendation accepted: canonical typed-JSON
  serialisation moves from DP-6 into DP-1, so downloads, CSV round-trip and
  db_export share one implementation.

Nine-point capability blast radius
: Verified accurate against the tree (spot-checked: @CAP_KEYS, %ACTION_INFO
  shape, t/lint/14/19/22/23/58 all exist and check what the brief says;
  regeneration via gen-capability-docs.pl byte-checked by t/tools/26).

Manager grounding
: The brief's cited paths (mg-editor-root, edit.md full-screen pattern,
  t/lint/32 nav-chunk coupling) verified; its warning stands - the
  manager-ui-guide chunk must ship inside DM-1 or t/lint/32 fails the build
  the moment the nav item lands.

# Still open - the release manager's, not the audit's

- **CSV parser**: own RFC-4180 subset vs Text::CSV dependency. Text::CSV is
  ABSENT on the reference host, which leans toward the shipped subset parser
  (small, fully testable, no new dep) - but it is a dependency-posture call.
  Needed by DM-2 at the earliest.
- **DBD driver set in the SBOM**: DBD::SQLite only, or declare
  DBD::Pg/DBD::mysql as installed-if-present now. Needed by DP-7, so not
  urgent.

# The consolidated map

Prerequisites, both landable in the current round (fixes, not features):

    SM409   the enabled gate - disabled means off
    SM411   extract Lazysite::Auth::Session from lazysite-auth.pl
            (closes SM402's open item; the data endpoint's identity)

Data plugin (DP) and data manager (DM), post-stable, audit-first per SM. The
manager brief supersedes plugin Part 7 and the manager half of plugin SM-5;
that is applied below, so nothing is built twice:

    DP-1  core: config/DSN, YAML::PP descriptor loader, SQLite adapter,
          DDL/DML generation, bound params, schema-state via the SM404
          checked writer, additive migrations, canonical typed-JSON
          serialiser (hoisted), MCP tool set, manage_data across the nine
          parity points. Built to ADR 0009's contract shape (owns
          declaration) from the first commit.
    DP-2  read bindings: db: source in tt_page_var, generated-query grammar,
          snapshot mode, scalars, ttl interaction.       [DP-1]
    DP-3  endpoint + live/client modes + helper JS + inline writable=
          writes; identity via Lazysite::Auth::Session; SM388/389/396
          conventions.                                    [DP-1, SM411]
    DP-4  forms "db" handler: server-side mapping, values-only,
          descriptor validation.                          [DP-1]
    DP-5  destructive-migration flow: db_migrate confirm; the manager
          confirmation UI lands in DM-5, built once.      [DP-1]
    DP-6  backup/portability: typed-JSON in site_backup AND site packages,
          apply-side restore, cross-engine restore test, package-apply
          rows-survive test.                              [DP-1]
    DP-7  Postgres/MySQL adapters, gated on demand.       [DP-1; decision]
    DP-8  docs pass.                                      [trails each]

    DM-1  capability shell + tables view + read-only grid + the
          manager-ui-guide chunk (t/lint/32).             [DP-1]
    DM-2  downloads: typed JSON + guarded CSV.            [DM-1]
    DM-3  row writes: insert/edit/delete via descriptors. [DM-1]
    DM-4  CSV import: staged validate/diff/confirm.       [DM-2; CSV decision]
    DM-5  descriptor editor + destructive-migration UI.   [DM-1, DP-5]
    DM-6  spreadsheet ergonomics.                         [DM-3, DM-4]
    DM-7  consolidated operator-docs pass + manual-check walk.
          Docs pass DONE 2026-08-23; the walk is WRITTEN (Task 5 in
          MANUAL-CHECKS-WALKTHROUGH) and needs a deployed build to run.

Minimum coherent releases: DP-1+2 (agent-populated data rendering on pages);
add DM-1+2 for operator visibility. DP-1..4 + DM-1..4 is the intended v1.

# Supersession

The BACKLOG.md "Database plugin" sketch is superseded: its named schemas
(session, profile, basket) are per-visitor state, which the settled boundary
excludes - tables hold SITE state; login-scoped data is an app and is split
out. The sketch's "values readable and writable in TT" survives as the db:
binding and the writable= declaration, with the trust direction fixed.
