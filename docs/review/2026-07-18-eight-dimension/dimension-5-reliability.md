# Dimension 5 - Reliability and resilience - lazysite eight-dimension review

- Candidate: 0.8.0-stable (0.7.28 tree at HEAD `6780878`)
- Date: 2026-07-18
- Regime: Commercial
- Assessor: independent close-out review

## Verdict

**PASS** (Commercial) - the prior review's single gating fact is cleared: an
SLO / error-budget / RTO / RPO declaration now exists (`docs/RELIABILITY.md`),
is mapped target-by-target to failure-mode tests that run in the suite, and is
backed by six timed restore rehearsals. The refusal condition that stood at
2026-07-01 and 2026-07-10 - "nothing to verify" - no longer holds. Two prior
WARNs remain open (no `docs/MONITORS.md`; no capacity test past the D4
baseline), but neither is a Commercial refusal condition for this dimension,
and no work since 0.7.0 re-opens a reliability gate.

One-line basis: the by-design gate for D5 refuses "a declared SLO without a
corresponding failure-mode test scenario"; every declared target in
`docs/RELIABILITY.md` now names an existing, passing scenario, so the gate
clears.

## Method

Assessed at HEAD `6780878` (`git status --short` clean; working tree equals the
release commit `release: 0.7.28 (BETA)`). Framework:
`/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 5 detail (SLOs as
percentile targets, error budgets, RTO, RPO, failure-mode tests, capacity
testing; waivable only when `output_types:` includes no runnable service) and
the by-design refusal conditions. Prior reviews:
`docs/review/2026-07-10-eight-dimension/dimension-5-reliability.md` (REFUSE) and
`docs/review/2026-07-01-eight-dimension/90-prelaunch-operational-holds.md`.
Commands and inspection:

- `grep -rniE 'SLO|RTO|RPO|error budget|recovery time|recovery point'` over
  `docs/` - now resolves to a dedicated declaration, `docs/RELIABILITY.md`
  (9.3 KB), referenced from `docs/POLICY.md` ("Operational resilience"). This
  file did **not** exist at the prior tag.
- Read `docs/RELIABILITY.md` in full: declared targets, error budget, the
  target-to-evidence mapping, the availability-measurement source, and the
  restore-rehearsal register (six dated rehearsals, 2026-07-10 .. 2026-07-12).
- Read `docs/adr/0008-stable-compatibility-freeze.md` (new; Proposed) - the
  audit-trail record format is named a frozen compliance surface, which
  reinforces the D5 availability-measurement source.
- `prove -l t/integration/23-layout-strings.t` PASS; the failure-mode tests the
  declaration cites remain in the tree (`t/integration/13-write-failure.t`,
  `t/integration/13-layout-compile-cache.t`); the FastCGI state-isolation
  pattern (`t/lib/MiniFcgi.pm`, SM142) adds a resilience surface the prior
  review had not yet seen at a stable candidate.
- The failure-mode tests this dimension relies on (`13-write-failure.t`,
  `13-layout-compile-cache.t`) PASS standalone. Note for Dimension 3: the
  aggregate `perl t/run-all.t` has 3 order-dependent failures
  (`t/unit/dav/05-copy-move.t`, `t/unit/manager/13-theme-pristine-backup.t`,
  `t/unit/manager/37-theme-delete-domains.t`) that all pass individually - a
  test-isolation issue in the theme/dav/domains area, not a reliability defect
  in the product. It does not touch any D5 evidence, so the verdict stands.
- Source spot-checks confirming the mapped machinery still exists at this tree:
  `lib/Lazysite/Manager/Backups.pm` (restore + prerestore snapshot),
  `install.pl` (`--restore-full --domain`), `tools/lazysite-check.pl`,
  the die-guard and `_tt_render` retry in `lazysite-processor.pl`, and the
  SM140 access-log recorder as the availability measurement source.

## Findings

### F5.1 - The SLO / error-budget / RTO / RPO declaration now exists (FIXED, was REFUSE)

`docs/RELIABILITY.md` is the artefact three prior cycles kept deferring. It
declares, as the project's reference posture for a single-host deployment:
page-serve availability 99.9% monthly; manager API and DAV 99.5% monthly, p99
under 2 s; RTO 4 h; RPO 24 h content, 0 shipped code (immutable git tag, ADR
0002), 24 h auth/config; and the derived monthly error budget (~43 min at
99.9%, ~3 h 40 m at 99.5%). It carries a budget policy (page-serve budget
exhaustion halts edge upgrades to that deployment until the window recovers -
the operation-phase instance of the by-design pattern) and names the SM140
access log as the availability measurement source. `docs/POLICY.md` now points
to it under "Operational resilience". This is the framework's required record;
the refusal trigger is gone.

The per-deployment ownership split (each operator may override) is preserved,
but - unlike the prior cycle - the project now ships a concrete reference
declaration rather than only the ownership note, so the "one operational
instance is due and absent" objection from F5.2 of the prior review is
answered by the reference posture standing as the posture of record.

### F5.2 - Target-to-evidence mapping is complete and the tests pass (PASS)

The framework's letter pairs every declared target with a failure-mode
scenario. `docs/RELIABILITY.md`'s mapping table does this for each target, and
each cited scenario exists and passes at this tree:

- **Page-serve availability** -> `t/integration/13-write-failure.t` (disk-full
  injection: torn cache rewrite dropped, old file survives; concurrent-writer
  no interleave) and `t/integration/13-layout-compile-cache.t` (compile-cache
  fault retries once on a fresh instance) - both still present; plus the
  die-guard 500 wrapper as the recorded-failure raw material.
- **RTO 4 h** -> `tools/lazysite-check.pl` first-line repair; the prerestore
  safety snapshot in `Backups.pm`; `install.pl --restore-full --domain`
  cross-domain DR.
- **RPO 0 (code)** -> ADR 0002 tagged-release contract; **RPO 24 h** ->
  content + full-system backups (scheduling operator-side).

The gate is satisfied: no declared SLO lacks a scenario. The tests already
existed at the prior tag; the missing half was the declaration, now supplied.

### F5.3 - Restore rehearsals recorded and timed (PASS, closes prior recommendation 2)

`docs/RELIABILITY.md` carries a rehearsal register with six dated entries
(2026-07-10 for the 0.7.0 cut through 2026-07-12 for the 0.7.13 cycle), each a
full-system disaster cycle (install, content + manager account, full backup,
docroot destroyed, `--restore-full --domain` onto a new docroot, content/auth/
conf verified intact) with wall-clock recovery recorded (~1 s mechanical
restore at starter-site scale; the 4 h RTO budget correctly attributed to
operator response + DNS, not the mechanism). This discharges the prior
review's recommendation 2 ("time one restore rehearsal and record it") and the
per-stable-cycle rehearsal commitment. **Gap:** the register stops at the
0.7.13 cycle (2026-07-12); the 0.8.0-stable candidate at 0.7.28 has no rehearsal
entry of its own. The commitment is "at least once per stable release cycle",
so a fresh rehearsal against the 0.7.28 tarball is due at the cut - effort S,
recommendation 1 below.

### F5.4 - New work since 0.7.0 does not re-open a reliability gate (PASS)

The significant work since the prior review (SM165 domain access, SM175 rename-
following history, SM179 multilingual, the manager UX run) is content-routing,
authorisation and presentation, not new failure surface on the serving path.
The one structural reliability change in the 0.7.x line - SM142's persistent
FastCGI accept loop (cross-request state-bleed risk) - is covered by a shared
`reset_request_state` + die-guard and pinned by the state-isolation test
pattern (`t/lib/MiniFcgi.pm`), and its assessment is recorded (`docs/SECURITY.md`
significant-change register, SM142). The multilingual work fails closed to
English for chrome (`Lazysite::I18n`: any miss - unknown language, missing key,
unreadable/invalid JSON - yields the English string; a mis-set language can
never blank a page), which is the correct availability posture for a display
concern. No declared target is invalidated.

### F5.5 - MONITORS.md and capacity test still absent (WARN, carried over)

Two prior WARNs stand, neither a Commercial refusal condition for D5:

- **No `docs/MONITORS.md`** - the operational-monitors register the holds doc
  promised as the project-side deliverable is still not created. This is the
  operation-phase counterpart of the release-time signoff; its absence is a
  documentation-dimension concern (D7 `operational_monitors`) more than a D5
  refusal, and the availability *measurement* source (the SM140 access log)
  does now exist and is documented, which is the substantive half.
- **No capacity test past the D4 baseline** - `grep -rE 'k6|wrk|capacity|ab '`
  over `t/` and `tools/` still finds nothing, so the CGI/FastCGI
  fork-saturation failure mode at the limit remains unobserved. The framework
  names capacity testing as a D5 element but does not make its absence a
  Commercial *refusal*; classified WARN, recommendation 2.

### F5.6 - Single points of failure (WARN, carried over in reduced form)

Per site everything rides one host and one filesystem; the per-site
`lazysite/auth/.secret` remains a genuine SPOF (sessions, CSRF, SM140 visitor
anonymisation, and now the SM165 scope resolution all read the same tree),
captured by full-system backups that exist on demand but on no shipped
schedule. Appropriate for the product class and unchanged in kind; the RPO that
bounds it is now declared (24 h), which is the improvement over the prior
cycle.

## Prior findings - disposition

```datatable
columns: Prior finding | Was | Now
widths: 7cm | 2.2cm | X
bold: 1
tone: medium
text: 3
---
F5.1 no SLO/RTO/RPO/error budget | REFUSE | FIXED - docs/RELIABILITY.md declares all four, mapped to tests
F5.2 ownership model not discharging refusal | WARN | Cleared - reference declaration now ships alongside the ownership split
F5.3 recovery machinery | PASS | PASS - unchanged; still present at this tree
F5.4 failure-mode test gaps | PASS | PASS - the named scenarios still run; SM142 adds state-isolation
F5.5 no capacity testing | WARN | WARN - unchanged
F5.6 health checks yes, monitoring no | WARN | WARN - no MONITORS.md; measurement source (access log) now documented
```

## Recommendations

Ranked; effort S/M/L; each names the framework gate it satisfies.

1. **Record a restore rehearsal for the 0.8.0-stable candidate** (0.7.28
   tarball) in `docs/RELIABILITY.md`'s register before the `--final` cut - the
   per-stable-cycle commitment the file itself states; the register currently
   stops at the 0.7.13 cycle. Effort S. Keeps the RTO/RPO claims evidenced at
   the shipped tag.
2. **Capacity test past the D4 baseline** (`ab`/`k6` until the fork path
   saturates under both plain-CGI and the SM142 pool; record the knee and the
   failure mode alongside the performance baseline). Effort M. The one
   framework-named D5 scenario class still missing; also feeds the FastCGI
   worker-recycling tuning (`LAZYSITE_FCGI_MAX_REQUESTS`).
3. **Ship `docs/MONITORS.md`** - the promised register (uptime probe,
   `lazysite-check` under cron, the access-log 5xx surface as the SLO
   measurement, log-rotation verification, `pentest-currency`) with cadence and
   last-run columns, worked once against one of the team's own production
   sites. Effort S-M. Satisfies the operation-phase counterpart (D7
   `operational_monitors`) and makes the declared error-budget policy
   executable.
4. **Adopt a one-file incident record** and backfill the 0.6.5-0.6.7 field
   round (date, versions, blast radius, time-to-recover, fix commit, test
   added). Effort S. Turns field incidents into error-budget accounting - the
   feedback loop the declared budget policy assumes.
