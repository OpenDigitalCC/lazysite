---
title: "Dimension 5 - Reliability and resilience - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

REFUSE - the prior review's single gating fact is unchanged: no SLO, error budget, RTO or RPO is declared anywhere in the repository, and for a Commercial-regime runnable service the framework's signoff verifies first that "the declared SLO/RTO/RPO targets are recorded" - there is still nothing to verify. Everything around the declaration has moved substantially in the right direction: the failure-mode test base that was the prior review's largest WARN is now genuinely strong (disk-full injection across processor cache, DAV PUT and forms; concurrent-writer races; TT compile-cache faults - all run and passing at this tag), the recovery machinery gained the missing restore half plus full-system backups with cross-domain restore, and the 0.6.5-0.6.7 field-incident round shows the failure-to-fix-to-test loop working on real production outages. The distance to a clean verdict is now almost purely declaratory - which makes the third missed opportunity to write the declaration (the holds doc itself said item 1 "can be drafted early") the finding, not the machinery.

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (working tree equals the tag; `git status --short` shows only this review directory untracked). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 5 detail (SLOs as percentile targets, error budgets, RTO, RPO, failure-mode tests, capacity testing; waivable only when `output_types:` includes no runnable service) and the by-design refusal conditions. Prior review: `docs/review/2026-07-01-eight-dimension/dimension-5-reliability.md` and `90-prelaunch-operational-holds.md` (ownership decision of 2026-07-04). Commands run:

- `grep -rniE 'SLO|RTO|RPO|error budget|service level|recovery time|recovery point'` over `docs/`, `README.md`, `CLAUDE.md`, `SECURITY.md`, `UPGRADE.md` - the only true hit is `docs/feature-requests/BACKLOG.md` line 176, which references the held declaration; `docs/POLICY.md` remains silent on operational resilience; `ls docs/RELIABILITY.md docs/MONITORS.md project.yml` - none exist.
- `prove -l t/integration/13-write-failure.t` - 4 subtests, PASS, 3 s (disk-full injection via `ulimit -f` + ignored `SIGXFSZ`: processor cache, DAV PUT, forms, concurrency).
- `prove -l t/integration/13-layout-compile-cache.t t/integration/14-access-log.t t/integration/14-bad-url-blocker.t t/unit/lib/14-notify.t t/unit/forms/05-smtp-validate.t` - 71 tests, all PASS.
- Full suite green cited from the release run at this tag: `/srv/tmp/sm-test/rel610-suite.log` - `Files=162, Tests=2504 ... Result: PASS` (not re-run here; owned by Dimension 3).
- Source inspection: `lazysite-processor.pl` (`_tt_render` retry, `apply_trust_gate`, the recorded-500 wrapper, `_access_record`), `lazysite-auth.pl` (rate-limit fail-open, CSPRNG fail-closed, `_bad_url_guard`), `lib/Lazysite/Manager/Backups.pm` (restore + safety snapshot + full-backup refusal), `install.pl` (`--restore-full`, `--domain`), `tools/lazysite-check.pl` (cache/tt probe, ownership repair, `--fix`), `lib/Lazysite/BadUrl.pm`, `lib/Lazysite/Notify.pm`, `installers/hestia/lazysite-logrotate`.
- CHANGELOG 0.5.36-0.6.10 read against the code for the 0.6.5-0.6.7 field-incident round.

## Findings

### F5.1 - Still no SLO, error budget, RTO or RPO declared (REFUSE, carried over)

The repository-wide grep again finds no declaration of availability, error-rate, recovery-time or recovery-point targets. `docs/POLICY.md` declares the Commercial regime and tracks CRA obligations but says nothing about operational resilience; there is no `docs/RELIABILITY.md`, no `docs/MONITORS.md`, no `project.yml`. The framework is unambiguous: the dimension is waivable only for projects with no runnable service, and "commercial-regime projects shipped to a customer or hosted as a service carry full SLO/RTO/RPO declarations". lazysite is both - operator-shipped software and a fleet the team itself runs (the 0.6.6 changelog and backlog record "ownership breakage across 17 production sites", so the live estate has grown since the prior review counted ~14).

The declaration has now been deferred three times: the prior review's recommendation 1 (effort S), the holds doc's item 1 (with proposed starting values and the note that it "can be drafted early and confirmed at launch"), and this development cycle. Nothing was drafted. Classification: REFUSE - the same trigger, verbatim.

### F5.2 - The per-implementation ownership model: coherent, but not discharging the refusal (WARN)

The holds doc (Status section, 2026-07-04) reassigns the operational review - SLO declaration, snapshot crons, log rotation, monitoring, CVE vigilance, pentest - to each deployment's operator, with the project owing two things: the mechanism, and "a worked example run against the dev server demonstrating what each item looks like in practice". Assessed against its own terms at this tag:

```datatable
columns: Hold item | Project-side promise | Delivered by v0.6.10
widths: 4.2cm | X | X
bold: 1
tone: medium
text: 2 3
---
1 SLO/RTO/RPO declaration | Draft early, confirm at launch | Not drafted - the refusal trigger
2 Scheduled snapshots | SM084 restore (dev half) | Restore shipped 0.5.37 with safety snapshot; full-system backups + cross-domain restore added 0.6.1; scheduling remains operator-side (correctly)
3 Log rotation | logrotate snippet | Shipped: `installers/hestia/lazysite-logrotate` (0.5.37); deployment operator-side
4 Monitoring/alerting | `docs/MONITORS.md` register + exemplar | Not created; no register, no exemplar document
5 CVE vigilance tooling | Wrapper scripts once packages installed | `debsecan`/`gitleaks` still not installed ("zero-risk, can be unblocked earlier"); no wrappers
6-8 Pentest, support period, compliance set | Declarations | Not declared (D6/D8 scope)
Worked exemplar | Operational run against `tools/lazysite-server.pl` | Does not exist as an artefact; the only references are the holds doc and a backlog pointer to the dev server itself
```

The split itself is defensible for genuinely per-deployment work (crons, probes, rotation deployment). It does not reach the declaration: the framework offers exactly one deferral shape for this dimension (`signoff.reliability.waived:` with a reason, available only when no runnable service is shipped), and the ownership note is not that artefact. Moreover, the team is itself the operator of a 17-site production fleet, so even on the model's own logic one operational instance of the review - the team's - is due and absent. The model is also under-delivering its project-side half: no exemplar, no monitors register, no early-drafted declaration. Classification: WARN - the ownership split is holding up for mechanisms, not for declarations or the exemplar.

### F5.3 - Recovery machinery: the prior gaps are closed (PASS, was WARN)

The prior review's asymmetry - "list/create/download exist; restore does not" - is gone, and the machinery now covers content, full-system and cross-domain recovery:

in-manager content restore (SM084, 0.5.37)
: `action_backup_restore` (`lib/Lazysite/Manager/Backups.pm` lines 75-104) takes a `prerestore` safety snapshot first and refuses to proceed if that snapshot fails, overlays the archive with `--no-same-owner`, and preserves legacy static pages when clearing cache. The restore is itself recoverable.

full-system backups and cross-domain restore (0.6.1)
: `action_backup_create('full')` captures the whole site including `lazysite/` (config, auth, forms, nav, themes/layouts). Because a full backup carries the auth secrets, in-app restore refuses it (`Backups.pm` lines 87-93) and `install.pl --restore-full <file> --docroot X [--domain Y]` restores from the shell, optionally rewriting the domain - a tested disaster-recovery and site-migration path (`install.pl` lines 80, 124, 174-179). This also closes the previously unstated gap that the per-site HMAC secret and account store had no typed backup.

pre-upgrade backups and retention
: unchanged from the prior review (`install.pl --restore`, `--list-backups`, `backup_retention`), still pinned by `t/tools/03-install-pl.t` in the green suite.

Classification: PASS. The residual is scheduling (F5.2 item 2): without a snapshot cron the content RPO is still unbounded between upgrades - now an operator deployment task with a complete mechanism behind it, but no declared RPO to hold it to (F5.1).

### F5.4 - Failure-mode tests: the named gaps are closed (PASS, was WARN)

The prior review listed five untested failure modes. Disposition:

```datatable
columns: Prior gap | Status at v0.6.10 | Evidence
widths: 4.5cm | 2.8cm | X
bold: 1
tone: medium
text: 3
---
Disk full (processor cache, DAV PUT, forms) | Closed | `t/integration/13-write-failure.t`: `ulimit -f 4` + ignored `SIGXFSZ` injects EFBIG (the ENOSPC-shaped path, no root needed); asserts the torn cache rewrite is dropped and the old complete file survives, DAV PUT answers 500 with the original intact, forms report failure not success. Run: 4 subtests PASS
Concurrent DAV writes | Closed | same file, concurrent-writer subtest - no interleaved file
Log rotation | Config shipped | `installers/hestia/lazysite-logrotate` (weekly, with install/verify instructions); fleet deployment is hold item 3
Cache-directory loss | Closed and field-proven | `t/integration/13-layout-compile-cache.t` plus `_tt_render` (`lazysite-processor.pl` lines 3076-3104): any compile-cache failure retries once on a fresh instance with the on-disk cache disabled; `lazysite-check` gained a `cache/tt` writability probe and `--fix` removes the tree (lines 243-267, 524-526)
Dependency outages (SMTP, XMPP) | Substantially covered | delivery is best-effort and time-boxed (`Lazysite::Notify` `alarm 15`; the bell store remains the record); `t/unit/lib/14-notify.t` exercises the unreachable-server path (observed in the run log); SM137 staged validation is itself an operator-facing dependency diagnostic
```

New since the prior review, `lazysite-processor.pl` lines 657-670 convert an unhandled processor `die` into a clean, logged 500 instead of a headerless crash (0.6.8) - failures are now recorded, which is the raw material an error budget would consume. Classification: PASS - the framework's named fault-injection list is materially covered for this architecture; the scenarios just have no declared targets to verify against.

### F5.5 - The 0.6.5-0.6.7 field-incident round: real failures, real fixes, no incident record (WARN)

Three production incidents inside one week are documented in the changelog and verified in code, and each closed the loop from failure to fix to probe/test:

fresh-install trap (0.6.5)
: a fresh 0.6.3 manager could not add its first user; `setup-manager` now guarantees the admin group's capabilities and a conf-declared manager group self-heals on any settings read.

ownership-repair regression (0.6.5 to 0.6.6)
: the 0.6.5 align-ownership pass chowned everything under `lazysite/`, stripping the CGI's group access and 500-ing the auth wrapper across 17 production sites; 0.6.6 scopes the repair to root-owned paths only and uses the web-server group, with `lazysite-check --fix` as the documented recovery. The systemic fix (packaging rework: "no root writes into site trees") is a recorded backlog item.

TT compile-cache outage (0.6.7)
: unwritable `lazysite/cache/tt` dirs took every layout render down (silent fallback chrome on TT 2.x, hard 500 on TT 3.x) on a live customer site; fixed by the `_tt_render` retry, a loud auth-gated manager banner, and a new check probe + `--fix` (F5.4).

This is exactly the operational evidence the dimension wants - and it is stored as changelog prose. There is no incident record carrying date, blast radius, time-to-recover or RTO-achieved, so the round contributes nothing measurable to a future error budget, and the de-facto recovery times it demonstrates (minutes-to-hours with `lazysite-check --fix`) are again undeclared. The 0.6.5 regression also shows why: an upgrade pass that broke 17 sites simultaneously is precisely the event an error-budget policy exists to price. Classification: WARN.

### F5.6 - Error handling on the auth path: coherent fail-open/fail-closed split, undocumented (PASS with a gap)

Inventory taken at this tag:

```datatable
columns: Path | Behaviour on failure | Direction | Evidence
widths: 4.2cm | X | 2.2cm | 3.8cm
bold: 1
tone: medium
text: 2
---
Trust headers | `HTTP_X_REMOTE_*` / `HTTP_X_PAYMENT_*` stripped unless `LAZYSITE_AUTH_TRUSTED=1` or operator opt-in; attempt logged | fail closed | `lazysite-processor.pl` 727-752
CSPRNG unavailable | dies rather than falling back to `rand()` | fail closed | `lazysite-auth.pl` 885-897
Auth secret unreadable | dies (login 500) | fail closed | `lazysite-auth.pl` 879
Manager/state writes | short write or failed flush unlinks the tempfile; no torn file installed | fail closed | `write_file_checked` + F5.4 tests
Login rate limit | DB_File tie failure admits the attempt so a broken store cannot lock out all logins | fail open (deliberate, commented) | `lazysite-auth.pl` 932-947
Bad-URL blocker | store open/parse failure means no block | fail open | `Lazysite::BadUrl` 78-82, 140-156
Corrupt user-settings.json | logged, defaults applied (no capability grants beyond defaults) | degrade | `Auth/Settings.pm` 157
TT compile cache | retry once without the on-disk cache; WARN logged | degrade | `lazysite-processor.pl` 3082-3104
Notifications / access record | strictly best-effort; never affects the request | fail open (correct for auxiliaries) | `Notify.pm`, `_access_record`
```

The split is principled - security decisions fail closed, availability-side auxiliaries fail open - but it exists only in code comments. The rate-limit fail-open in particular is a deliberate trade (an attacker who can corrupt `.login-rate.db` removes brute-force protection) that belongs in the security model's residual-risk record, and the whole inventory belongs in the reliability declaration this dimension keeps not getting. Classification: PASS on behaviour, gap on documentation.

### F5.7 - Single points of failure (WARN, carried over in reduced form)

Per site everything rides one host and one filesystem - appropriate for the product class, but the per-site `lazysite/auth/.secret` is a genuine SPOF (sessions, CSRF tokens, and now the SM140 visitor-key anonymisation all derive from it) and is captured only by full-system backups, which exist on demand but on no schedule. The web server and panel are out of scope. Optional dependencies (SMTP, XMPP) degrade correctly. The remaining structural gaps from the prior review stand: no capacity test at or past the Dimension 4 baseline (grep for `k6|wrk|capacity` over `t/` and `tools/` - nothing), so the CGI fork-saturation failure mode at the limit is still unobserved; no `docs/MONITORS.md`; nothing measures an SLO and no error budget is tracked. Classification: WARN.

## Prior findings - disposition

```datatable
columns: Prior finding | Was | Now
widths: 7cm | 2.2cm | X
bold: 1
tone: medium
text: 3
---
F5.1 no SLO/RTO/RPO/error budget | REFUSE | REFUSE - unchanged; deferred a third time
F5.2 code/state recovery machinery | PASS | PASS - strengthened (full-system + cross-domain restore)
F5.3 undeclared, asymmetric RTO/RPO | WARN | Half-cleared: restore asymmetry closed; declaration still absent
F5.4 failure-mode test gaps | WARN | PASS - all five named gaps closed or config-shipped
F5.5 no capacity testing | WARN | WARN - unchanged
F5.6 health checks yes, monitoring no | WARN | WARN - `lazysite-check` further strengthened; no MONITORS.md, no alerting, no budget tracking
```

## Recommendations

Ranked; effort S/M/L; each names the framework gate it satisfies.

1. **Write the declaration - this clears the refusal.** Add `docs/RELIABILITY.md` (referenced from `docs/POLICY.md`) recording, as the project's shipped reference posture with a per-deployment override note: page-serve availability 99.9% monthly; manager API and DAV 99.5% monthly, p99 under 2 s; RTO 4 h (operator-driven `lazysite-check --fix` / `install.pl --restore` / `--restore-full`); RPO 24 h content, 0 shipped code, 24 h auth/config (via a scheduled full backup); the derived monthly error budget (~43 min at 99.9%). Then map each target to its existing failure-mode test - `13-write-failure.t`, `13-layout-compile-cache.t`, the restore round-trips - because the framework's letter pairs every declared SLO with a scenario. The tests already exist; the declaration is the missing half of the by-design gate. Effort S.
2. **Time one restore rehearsal and record it** - run the content-restore and `--restore-full --domain` paths against a copy of a production-shaped site and record wall-clock recovery in the declaration, so the RTO/RPO claims carry evidence ("the latest run passed"). Effort S.
3. **Ship the promised exemplar and `docs/MONITORS.md`.** The holds doc's own project-side deliverable: a monitors register (uptime probe, `lazysite-check` under cron, the stats error surface, log-rotation verification) with cadence and last-run columns, worked once against the dev server or one of the team's own 17 production sites. Effort S-M. Satisfies the operation-phase counterpart and makes hold items 2-4 executable per deployment.
4. **Schedule snapshots on the team's own fleet** - cron per site calling the existing `action_backup_create` (content daily, full weekly), bounding the declared RPO on the one deployment the project itself operates. Effort S.
5. **Capacity test past the Dimension 4 baseline** (`ab` or `k6` until the CGI fork path saturates; record the knee and the observed failure mode alongside the performance baseline). Effort M. The one framework-named scenario class still missing.
6. **Adopt a one-file incident record** (date, versions, blast radius, time-to-recover, fix commit, probe/test added) and backfill the 0.6.5-0.6.7 round. Effort S. Turns field incidents into error-budget accounting and gives the declaration its operational feedback loop.
7. **Document the fail-open/fail-closed inventory** (the F5.6 table, especially the deliberate rate-limit fail-open) in `docs/architecture/security.md`'s residual-risk section and the new RELIABILITY.md. Effort S.
