---
title: "lazysite - Reliability and resilience declaration"
subtitle: "SLOs, error budget, RTO/RPO, evidence mapping, and restore rehearsals (eight-dimension review D5)"
brand: plain
---

# Scope and ownership

This document is the project's declared **reference reliability posture**
for a single-host deployment - one web server, one filesystem, the CGI
processor and auth wrapper in front of a static tree. It exists to satisfy
the eight-dimension framework's Dimension 5 requirement that SLO, error
budget, RTO and RPO targets are recorded and mapped to failure-mode
evidence.

Ownership follows the model recorded in
`docs/review/2026-07-01-eight-dimension/90-prelaunch-operational-holds.md`
(decision of 2026-07-04): lazysite is deployed by many operators onto
their own infrastructure, so the operational reliability commitment is
**per implementation**. The project ships the mechanism (backups and
restore, `lazysite-check`, the failure-mode test suite, the access log
that measures availability) plus this reference declaration; **each
operator may override these targets for their deployment**. Where an
operator declares nothing, this reference posture is the posture of
record for their deployment class.

# Declared reference targets

```datatable
columns: Target | Value | Notes
widths: 4.4cm | 4.2cm | X
bold: 1
tone: medium
text: 3
---
Page-serve availability | 99.9% monthly | Anonymous page rendering and static serving - the product's core promise
Manager API and DAV availability | 99.5% monthly, p99 under 2 s | Authoring surfaces; lower target reflects upgrade windows and operator maintenance
Recovery Time Objective (RTO) | 4 hours | Operator-driven recovery via `lazysite-check --fix`, `install.pl --restore`, or `install.pl --restore-full`
RPO - site content | 24 hours | Bounded by a daily scheduled content backup (operator cron calling `action_backup_create`)
RPO - shipped code | 0 (zero loss) | Code is never backed up because it is never at risk - every release is an immutable git tag, re-installable at any time (ADR 0002)
RPO - auth and configuration | 24 hours | Bounded by a scheduled full-system backup, which captures `lazysite/` including the per-site HMAC secret and account store
```

The targets are those proposed in the 2026-07-01 review's holds document
(item 1) and carried through the 2026-07-10 Dimension 5 report. They are
declared now as the project's reference values; the launch-time hosting
decision confirms or overrides them per deployment.

# Error budget

The budget is derived directly from the SLOs over a calendar month
(30-day basis):

```datatable
columns: Surface | SLO | Monthly error budget
widths: 5.2cm | 3.4cm | X
bold: 1
tone: medium
---
Page serving | 99.9% | ~43 minutes of unavailability, or the equivalent share of 5xx responses
Manager API and DAV | 99.5% | ~3 hours 40 minutes
```

Budget policy: when a deployment's page-serve budget for the month is
exhausted, no further edge-channel upgrades are applied to that
deployment until the budget window recovers - stability work (probes,
fixes, rehearsals) takes precedence over feature rollout. This is the
operation-phase instance of the framework's by-design prevention
pattern. Field incidents consume the budget: the 0.6.5–0.6.6 ownership
regression, which 500-ed the auth wrapper across 17 production sites,
is exactly the class of event this budget exists to price.

# Target-to-evidence mapping

The framework's letter pairs every declared target with a failure-mode
scenario. Each target above maps to evidence that already exists and
runs in the suite:

```datatable
columns: Target | Failure-mode evidence | Where
widths: 4cm | X | 5.4cm
bold: 1
tone: medium
text: 2
---
Page-serve availability | Disk-full injection (processor cache, DAV PUT, forms) - a torn cache rewrite is dropped and the old complete file survives; concurrent-writer races produce no interleaved file | `t/integration/13-write-failure.t` (4 subtests)
 | TT compile-cache faults - any compile-cache failure retries once on a fresh instance with the on-disk cache disabled, so an unwritable cache cannot take rendering down | `t/integration/13-layout-compile-cache.t`; `_tt_render` retry in `lazysite-processor.pl`
 | Unhandled processor `die` becomes a clean, logged and recorded 500 rather than a headerless crash (0.6.8) | die-guard wrapper in `lazysite-processor.pl` (SM140)
RTO 4 h | `lazysite-check` is the first-line repair tool: cache/TT writability probe, ownership repair, secrets-mode probe, `--fix` | `tools/lazysite-check.pl`
 | Content restore takes a `prerestore` safety snapshot first and refuses to proceed if that snapshot fails - the restore is itself recoverable | `lib/Lazysite/Manager/Backups.pm` (SM084, 0.5.37)
 | Cross-domain disaster recovery: `install.pl --restore-full <file> --docroot X [--domain Y]` restores a full-system backup from the shell, optionally rewriting the domain | `install.pl` (0.6.1)
RPO 0 (code) | The uncommitted-tree/tagged-release contract: a release is an immutable tag packaged from a clean checkout, so shipped code is always recoverable byte-exact from the tag | ADR 0002; `tools/release.sh`
RPO 24 h (content, auth/config) | Content backups plus full-system backups (config, auth, forms, nav, themes/layouts); scheduling is the operator-side half that bounds the window | `action_backup_create` / `action_backup_create('full')`
Validated failure modes | The 0.6.5–0.6.7 field-incident round - fresh-install trap, fleet ownership regression, TT compile-cache outage - each closed the loop from production failure to fix to probe/test, and demonstrated minutes-to-hours recovery with `lazysite-check --fix` | CHANGELOG 0.6.5–0.6.7; the probes and tests named above
```

The fail-open/fail-closed inventory behind these behaviours (security
decisions fail closed; availability-side auxiliaries fail open) is part
of the security model - see `docs/SECURITY.md` and
`docs/architecture/security.md`.

# Measuring availability

The SM140 first-party access log is the availability measurement source.
The processor records the outcome of every request - including the
500s emitted by the die-guard - to
`lazysite/logs/access-YYYYMMDD.jsonl`, with status codes, anonymised
visitor keys and a 90-day default retention that comfortably covers the
monthly reporting window. Availability for a month is computed from
those files as the share of requests answered without a 5xx status;
the error budget consumed is the complement. No external probe is
required for the measurement itself, though an external uptime probe
remains the recommended alerting complement (holds item 4) - the log
cannot record requests the host never received.

# Restore rehearsals

Every declared RTO/RPO value must be backed by a timed rehearsal - a
restore run against a production-shaped site with wall-clock recovery
time recorded here - so the claims carry evidence, not just mechanism.
Rehearsals are repeated at least once per stable release cycle.

```datatable
columns: Date | Rehearsal | Recovery time | Notes
widths: 2.6cm | X | 3cm | 5cm
bold: 1
tone: medium
---
2026-07-10 | Full-system disaster rehearsal (0.7.0 cut) | ~1 s mechanical restore | Full cycle from the shipped 0.6.10 tarball: install, operator content + manager account, `action_backup_create('full')`, docroot destroyed, `install.pl --restore-full --domain` onto a NEW docroot - content, auth store and conf verified intact. The mechanical restore is effectively instantaneous at starter-site scale; the 4 h RTO budget is operator response + DNS, not the mechanism. Script: rehearsal.sh (session records)
 2026-07-11 | Full-system disaster rehearsal (0.7.7 stable cycle) | <1 s mechanical restore | Same full cycle against the shipped 0.7.6 tarball: install, content + manager, full backup, docroot destroyed, --restore-full --domain onto a new docroot - content, auth store and conf verified intact. Per-stable-cycle commitment met
 2026-07-11 | Full-system disaster rehearsal (0.7.8 stable cycle) | <1 s mechanical restore | Same full cycle against the shipped 0.7.7 tarball - content, auth store and conf verified intact on the new docroot. Per-stable-cycle commitment met
 2026-07-11 | Full-system disaster rehearsal (0.7.11 stable cycle) | <1 s mechanical restore | Same full cycle against the shipped 0.7.10 tarball - content, auth store and conf verified intact on the new docroot. Per-stable-cycle commitment met
```

# References

- `docs/POLICY.md` - the regulatory posture this declaration feeds
  (CRA quality floors; the Declaration of Conformity cites this file).
- `docs/review/2026-07-10-eight-dimension/dimension-5-reliability.md` -
  the review that mandated this declaration.
- `docs/adr/0002-uncommitted-tree-release-contract.md` - the tagged-release
  recovery contract behind the zero code-loss RPO.
