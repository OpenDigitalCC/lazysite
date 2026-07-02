---
title: "Dimension 5 - Reliability and resilience - lazysite eight-dimension review"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime"
brand: plain
---

## Verdict

REFUSE - lazysite is a runnable service (Commercial regime, ~14 live multi-tenant Hestia sites) so this dimension is not waivable, yet no SLO, error budget, RTO or RPO is declared anywhere in the repository; the framework's signoff verifies first that "the declared SLO/RTO/RPO targets are recorded", and there is nothing to verify. The distance to WARN is short: genuine recovery machinery and a real failure-mode test base already exist, so the gap is chiefly declaratory plus a handful of missing fault-injection scenarios.

## Method

Assessed at tag `v0.5.35`, commit `de12238` (working tree clean apart from this review directory). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 5 detail (SLOs as percentile targets, error budgets, RTO, RPO, failure-mode tests, capacity testing; waivable only when `output_types:` includes no runnable service) and the by-design refusal conditions. Commands run:

- `grep -rniE 'SLO|RTO|RPO|error budget|service level|recovery time|recovery point'` over `docs/`, `README.md`, `CLAUDE.md`, `SECURITY.md`, `UPGRADE.md` - only false positives (`slot`, `slow`, `purpose`).
- `prove -l t/tools/03-install-pl.t` - 22 subtests, all pass, 16 s wallclock (backup, retention, restore, verify).
- `prove -l t/unit/auth/03-login-rate-limit.t t/integration/06-deny-consistency.t t/journey/04-edge-cases.t` - 34 tests, all pass, 7 s.
- Source inspection: `install.pl` (backup/restore/retention), `lib/Lazysite/Manager/Backups.pm` (SM084), `lib/Lazysite/Manager/Themes.pm` (snapshots), `lazysite-dav.pl` (lock/423 contract), `lib/Lazysite/Auth/Settings.pm` (corrupt-JSON path), `lazysite-manager-api.pl` (SM020 checked writes), `tools/lazysite-check.pl`.
- Absence checks: `ls docs/MONITORS.md` (no such file); `grep -rn logrotate installers/ docs/ dist/` (no hits); grep for disk-full / ENOSPC tests in `t/` (none).

## Findings

### F5.1 - No SLO, error budget, RTO or RPO declared (REFUSE)

The repository-wide grep found no declaration of availability, error-rate, latency, recovery-time or recovery-point targets. `docs/POLICY.md` selects the Commercial regime and tracks CRA Article 13 obligations but says nothing about operational resilience. The framework is explicit: "commercial-regime projects shipped to a customer or hosted as a service carry full SLO/RTO/RPO declarations", and the signoff verifies the targets are recorded before it looks at anything else. With ~14 live customer sites this is the dimension's gating fact. Classification: REFUSE.

### F5.2 - Code/state recovery machinery exists and is tested (PASS)

`install.pl` implements `--restore`, `--restore --backup PATH` and `--list-backups`; pre-upgrade backups accumulate under `{docroot}/lazysite/backups/` and are pruned per `backup_retention` (default 3, `install.pl` line 933 validates the value and dies on a non-integer; documented at `docs/development.md` line 297). `t/tools/03-install-pl.t` pins the behaviour with passing subtests including "backup created, extracts, contains state file", "backup_retention: 3 keeps 3 most recent", "backup_retention: 0 keeps all", "restore most recent backup: files return to prior state" and "restore --backup PATH: named tarball restored" (run output: `Files=1, Tests=22 ... Result: PASS`). Theme/layout changes are additionally protected by `_snapshot_artifact` in `lib/Lazysite/Manager/Themes.pm`, taken under an artifact-level lock across validate -> snapshot -> flip and pruned by the same retention key. Classification: PASS.

### F5.3 - De-facto RTO/RPO exist but are undeclared and asymmetric (WARN)

From the machinery in F5.2 a de-facto posture can be inferred, which is exactly what a declaration should capture:

- Code and state: RTO in the order of minutes for an operator with shell access (`install.pl --restore`); RPO effectively zero for shipped code (reinstallable from the release tarball).
- Content: SM084 backups (`lib/Lazysite/Manager/Backups.pm`) are taken pre-install by the Hestia hook or manually from the manager; list/create/download exist but **restore does not** - `docs/feature-requests/BACKLOG.md` lines 67-68: "SM084 restore - in-manager 'restore this snapshot' (list/create/download exist; restore does not)". Content changed since the last snapshot has no in-product protection, so the content RPO is unbounded between upgrades unless the operator snapshots manually or runs host-level backups (out of lazysite's scope but currently also unstated).

Classification: WARN - real capability, no declared target to hold it to, and the content-restore half is an open backlog item.

### F5.4 - Failure-mode tests: real but partial coverage (WARN)

Failure modes that ARE tested (all runs passed):

- Login rate-limit saturation at the exact boundary - `t/unit/auth/03-login-rate-limit.t` seeds the DB_File state to test the Nth (passes) and N+1th (429/"rate") attempts.
- WebDAV lock contention - `lazysite-dav.pl` returns 423 for foreign locks (lines 620, 637, 692-700) with a documented 423/429 retry contract (line 1448); unit-tested in `t/unit/dav/06-lock.t`, `07-conditionals.t`, `10-rate-limit.t` and exercised in `t/journey/05-webdav-publish.t`.
- Deny-list consistency - `t/integration/06-deny-consistency.t` pins one canonical agent-facing deny list against its two rendered copies and the dav's enforcement.
- Cross-subsystem edge cases - `t/journey/04-edge-cases.t` (unicode round-trips, empty front matter and other boundary conditions).
- Corrupt state tolerance - `lib/Lazysite/Auth/Settings.pm` line 118 logs "user-settings.json unparseable; using defaults" and degrades rather than dying.
- Partial-write protection - SM020 centralised checked writes in `lazysite-manager-api.pl` (comment at line 745): every manager write path checks for the "ENOSPC/EIO/quota blind spot" and unlinks half-written files on failure.

Failure modes NOT tested (the framework's fault-injection list names disk full explicitly, and this host has historically hit it):

- **Disk full** - the SM020 pattern covers manager writes only; the processor's `.html` cache writes, DAV PUT bodies and form-submission spooling have no ENOSPC fault-injection test.
- **Log rotation** - no logrotate configuration is shipped (`grep -rn logrotate installers/ docs/ dist/` - no hits); the audit reader is "rotation/truncation-aware" (`lazysite-manager-api.pl` line 1232) but nothing in-product or in the installers rotates; unbounded log growth is itself a disk-full vector on a multi-tenant host.
- **Concurrent DAV writes** - lock semantics are unit-tested single-process; there is no multi-process contention test racing two writers.
- **Cache-directory loss** - regenerate-on-miss is the design (cache is `.html` beside `.md`), but no test pins that a deleted cache tree self-heals.
- Dependency outages (SMTP, form webhooks, remote `:::include` fetches) degrade in code but have no injected-outage tests.

Classification: WARN.

### F5.5 - No capacity testing (WARN)

`docs/architecture/performance.md` records concurrency numbers at normal load (10 concurrent cache-hit requests, ~3.6x speedup) - that is the Dimension 4 baseline. Nothing tests at or beyond the baseline to identify the failure mode at the limit, which for a CGI process-per-request architecture is the obvious question (fork saturation under a crawler burst or upload storm). Classification: WARN.

### F5.6 - Health checks exist; monitoring and alerting do not (WARN)

`tools/lazysite-check.pl` is a genuine operational doctor: per-check OK/WARN/FAIL with remediation hints, `--fix` for safe chmod/chown repairs, `--check-dav URL` probing that the /dav/ route answers 401 not 404, plus provenance auditing; it is tested in `t/tools/04-check.t`. But it is pull-only: there is no `docs/MONITORS.md` (the framework's operation-phase counterpart of the release gates), no uptime or alerting integration in-repo, and no error-budget tracking - so an SLO, once declared, would have nothing measuring it. Classification: WARN.

## Recommendations

Ranked; effort S/M/L; each names the framework gate it satisfies.

1. **Declare SLO/RTO/RPO** in a new section of `docs/POLICY.md` (or `docs/RELIABILITY.md` referenced from it). Concrete starting values consistent with the measured architecture: page-serve availability 99.9% monthly (static/cache-hit path); manager API availability 99.5% monthly with p99 latency under 2 s; DAV availability 99.5% monthly; RTO 4 h (operator-driven `install.pl --restore` plus content snapshot restore); RPO 24 h for content (daily snapshot), 0 for shipped code. Derive the error budget in the same section (99.9% monthly = ~43 min). Effort S. Satisfies "SLO/RTO/RPO targets recorded" - the current REFUSE trigger.
2. **Bound the content RPO**: implement SM084 restore (the open half) and add a scheduled per-site snapshot (cron calling the existing `action_backup_create` path), with a round-trip test proving restore lands within the declared RPO. Effort M. Satisfies "failure-mode test ... recovers within RTO/RPO".
3. **Disk-full fault injection**: a test that fills a small loopback/tmpfs docroot (or applies a quota) and asserts the processor cache write, DAV PUT and form submission all fail closed without corrupting existing files; extend the SM020 checked-write pattern to the processor and DAV write paths. Effort M. Satisfies the named "disk full" failure-mode scenario; directly addresses a failure this host has actually experienced.
4. **Ship log rotation**: a logrotate snippet in `installers/` for `lazysite/logs/` and the audit log (the reader is already rotation-aware, so this is config only). Effort S. Removes the standing disk-full vector.
5. **Create `docs/MONITORS.md`** and wire minimal alerting: external uptime probe per site plus `lazysite-check.pl` under cron with failure notification through the operator's existing channel. Effort S-M. Satisfies the operation-phase counterpart (SLO measurement, error-budget tracking).
6. **Capacity test**: `ab` or `k6` run past the Dimension 4 baseline until the CGI fork path saturates; record the observed failure mode and the knee point next to the performance baseline. Effort M. Satisfies "capacity testing ... to identify the failure mode at the limit".
7. **Concurrent-writer DAV test**: two racing PUT processes against one resource asserting exactly one wins and the loser receives the documented 423/429 contract. Effort S. Closes the multi-process gap in the otherwise good lock coverage.
