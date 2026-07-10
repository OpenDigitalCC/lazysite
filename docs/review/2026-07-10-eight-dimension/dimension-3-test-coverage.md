---
title: "Dimension 3 - Test coverage - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

WARN - the machinery the prior review demanded is now in place and working: the full suite runs green (162 files, 2504 tests), statement **and** branch floors are declared and enforced, the instrumented coverage gate is wired into `tools/release.sh` so a floor breach is unshippable, and a fresh full measurement at this tag puts every gated CGI at 79.5-93.6% statements / 62.5-72.9% branches - factually above the Commercial regime's 75% statement floor, not just the local 60% ratchet floor. The WARN rests on gate scope and gate integrity: two production CGIs added since the gate was defined (`lazysite-mcp.pl`, `lazysite-oauth.pl`) are measured but ungated - and `lazysite-oauth.pl` at 58.9% branches would fail the branch floor today if gated - and the `--check` loop treats a "not measured" CGI as a silent skip rather than a failure, which is precisely the regression mode that hid `lazysite-auth.pl` from measurement for weeks.

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (working tree equals the tag). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 3 detail ("the test suite runs, passes, and meets the line- and branch-coverage thresholds the regime sets"; Commercial coverage floor 75%) and the by-design prevention catalogue ("a coverage-threshold breach refuses the release, not a reminder ... a failing test in the suite refuses the release unconditionally"). Prior review: `docs/review/2026-07-01-eight-dimension/dimension-3-test-coverage.md` (v0.5.35), each finding re-verified. Commands run:

- `bash tools/coverage.sh --check` - the full instrumented run, executed to completion at this tag (roughly 35 minutes; every subprocess CGI instrumented via `PERL5OPT`, single merged `cover_db`).
- The full plain suite was **not** re-run: it ran green at this tag during the release and the log was verified (`/srv/tmp/sm-test/rel610-suite.log`: `Files=162, Tests=2504 ... Result: PASS`).
- `find t/ -name '*.t'` inventory, counted by area; read `dist/config/coverage-floor`, `tools/coverage.sh`, `tools/release.sh`, `docs/architecture/test-coverage.md`; `git log --follow` on the floor file and gate script.
- Feature-pinning audit: `git log --name-only v0.6.1..v0.6.10 -- t/` cross-referenced against every CHANGELOG entry for 0.6.2-0.6.9, then the matched test files read for assertion quality (`t/integration/13-layout-compile-cache.t`, `t/integration/14-access-log.t`, `t/unit/lib/14-notify.t`, `t/unit/users/15-setup-manager-caps.t`).
- Flake re-check: read the de-flake guard in `t/unit/auth/03-login-rate-limit.t`; grep for `TODO`-marked assertions across `t/`.

## Findings

### F3.1 - Suite inventory and growth (PASS)

162 `.t` files under `t/` (was 139 at v0.5.35; assertions 2003 to 2504, +25% across the 0.5.36-0.6.10 line):

```datatable
columns: Area | Files | Content
widths: 3.5cm | 1.5cm | X
bold: 1
tone: light
---
t/unit/ | 122 | processor, auth, dav, manager, users, forms, plugins, lib (module handlers), mcp, oauth, tools function-level tests
t/integration/ | 19 | render pipeline, cache hit, auth flow, preview, DAV publish, write-failure injection, TT compile-cache resilience, first-party access log
t/journey/ | 5 | multi-step scenarios (site setup, auth, forms, edge cases, WebDAV lifecycle)
t/tools/ | 8 | manifest, SBOM, bundle-apply, install.pl, check, capability docs, host deps
t/lint/ | 6 | stale paths, perlcritic sev-3, secrets, compile sweep, security perlcritic, tidy
t/smoke/ | 1 | every starter page renders
t/run-all.t | 1 | aggregate runner (skipped under prove -r)
```

The lint tier doubled since the prior review (compile sweep, security-themed perlcritic and the changed-code tidy gate all run under `prove`, hence inside the release gate). No `TODO`-marked assertions remain in the suite - the query-string mojibake `TODO` the prior review noted has been fixed and removed.

### F3.2 - Full suite green at this tag (PASS)

The release-time run at `5aa6f27`, verified in `/srv/tmp/sm-test/rel610-suite.log`:

```text
All tests successful.
Files=162, Tests=2504, 203 wallclock secs (0.52 usr 0.21 sys + 145.71 cusr 15.88 csys = 162.32 CPU)
Result: PASS
```

2504 of 2504 assertions pass. The framework's unconditional refusal condition (a failing test) is not triggered, and since 0.5.36 it is mechanically enforced: `tools/release.sh` refuses the release on a `prove` failure.

### F3.3 - Statement and branch floors declared and enforced (FIXED, was WARN)

`dist/config/coverage-floor` declares `floor=60` (statements) **and** `branch_floor=60`, with a per-file override mechanism (`branch_floor[FILE]=NN`) used once for `lazysite-manager-api.pl` (its branch measurement swings 56.6-80.7% run to run under subprocess instrumentation - a merge-timing artefact, documented in the floor file with an explicit "never lower the others" ratchet note). `tools/coverage.sh --check` enforces both columns per gated CGI. The prior review's framework non-conformance (statement-only threshold) is closed.

### F3.4 - Fresh measurement, all gated CGIs above floor (PASS)

`bash tools/coverage.sh --check` at `5aa6f27`, full instrumented run, exit 0:

```datatable
columns: Gated CGI | stmt | bran | Floors | Result
widths: 6cm | 1.8cm | 1.8cm | 2.4cm | X
bold: 1
tone: light
---
lazysite-dav.pl | 93.6% | 72.9% | 60/60 | ok
tools/lazysite-bundle-apply.pl | 89.8% | 65.0% | 60/60 | ok
tools/lazysite-users.pl | 89.0% | 70.8% | 60/60 | ok
lazysite-processor.pl | 85.3% | 71.6% | 60/60 | ok
lazysite-auth.pl | 82.1% | 62.5% | 60/60 | ok
lazysite-manager-api.pl | 79.5% | 62.7% | 60/60 | ok
```

Whole-tree totals: 91.6% statements / 61.7% branches across everything the suite touches. Two prior-review staleness problems are gone at once: the measurement is current (taken at the reviewed tag, today), and it can no longer go stale because the gate runs on every release. Note also that every gated CGI now measures above the Commercial regime's 75% statement floor on its own merits - the enforced 60% floor is the ratchet, not the reality. `lazysite-manager-api.pl` rose from 71% to 79.5% statements (the 0.5.41 read-action tests); its branch figure of 62.7% clears the floor this run but sits inside the documented variance band, so the floor file's dial-back caveat remains live.

### F3.5 - Coverage gate wired into release.sh (FIXED, was WARN)

`tools/release.sh` runs, on the staged tree: `prove -r`, `bench.pl --check`, `coverage.sh --check` (refusing on a floor breach - "coverage below the declared floor; not releasing"), then the strict SBOM gate. `docs/development.md` confirms `release.sh` is the only path a tag is cut through. The by-design refusal the Commercial regime expects has been mechanical since 0.5.36 - the prior review's central finding is closed.

### F3.6 - Gate scope: auth joined; mcp and oauth did not (WARN)

`lazysite-auth.pl` - the prior review's headline exclusion - is now gated (82.1%/62.5%). The root cause was a measurement split, fixed by `TestHelper::env_passthrough()` in every `%ENV`-rebuilding test; the same fix resolved the `Manager::Plugins` (21% to 66%) and `Manager::Upload` (37% to 82%) under-measurement artefacts.

However, the gate list has not kept pace with the production surface. The full report shows two partner-facing production CGIs measured but ungated, with no mention in the floor file's documented-exclusions note (unlike `install.pl`, whose exclusion is documented):

```datatable
columns: Ungated CGI | stmt | bran | Against the 60/60 floors
widths: 5cm | 1.8cm | 1.8cm | X
bold: 1
tone: light
---
lazysite-mcp.pl | 90.2% | 62.6% | would pass
lazysite-oauth.pl | 79.0% | 58.9% | would FAIL the branch floor
```

`lazysite-oauth.pl` below the declared branch floor is a real threshold gap, invisible only because the file is not in the `--check` loop. Classification: WARN - an undocumented scope gap in the gate, one member of which is under the declared floor.

### F3.7 - Gate integrity: "not measured" is a silent skip (WARN)

In `tools/coverage.sh --check`, a gated CGI whose report row is absent prints `not measured` to stderr and `continue`s - it does not set the failure flag. If instrumentation regresses (a new test rebuilding `%ENV` without `env_passthrough()` - exactly what hid `lazysite-auth.pl` for weeks), the gate would pass silently with that CGI unmeasured. Under the by-design prevention pattern the gate is "the only line of defence"; a defence that skips what it cannot see is not fail-closed. Classification: WARN - a one-line fix converts the project's own documented failure history into a refusal.

### F3.8 - New features and field fixes are pinned by tests (PASS, one gap)

Every headline change in 0.6.2-0.6.9 landed with same-commit tests, and the sampled tests assert on real behaviour, not fixtures:

- **SM136 notifications** - `t/unit/lib/14-notify.t`: bell-store append asserted on the actual `notices.jsonl` file; XMPP delivery gating tested through an injectable sender seam (the gating logic is the subject, not the mock).
- **SM138 manager_groups retirement** - eight test files updated in the breaking commit; `t/unit/users/15-setup-manager-caps.t` reproduces the 0.6.3 field incident (fresh install, admin group with no capability entry) and asserts both the guarantee and the self-heal on re-run.
- **SM140 first-party analytics** - `t/integration/14-access-log.t`: 40+ assertions end-to-end - per-request lines, channels, cache flag, anonymised visitor key (raw IP asserted absent from the file *and* the export), log-injection stripping, retention prune, the off switch, plus the stats aggregation and AI-export increments including incremental-offset idempotence.
- **0.6.7 TT compile-cache resilience** - `t/integration/13-layout-compile-cache.t`: three subtests including the negative cases (no error banner and no template-error leak to anonymous visitors; loud banner on auth-gated manager pages).

The gap: the 0.6.6 fix (`install.pl` ownership repair scoped to root-owned files - itself the repair of a field regression introduced by 0.6.5's ownership pass, which stripped the CGI's access on affected sites) shipped with **no test**, and `install.pl` is also the one production script outside the coverage gate - the project's least-protected file has now taken two consecutive field-hit regressions in one release pair. The 0.6.7 plugin-save audit refinement (diff against the existing conf, "(no changes)" case) is only partially pinned - `t/unit/manager/19-audit-target.t` pins key naming from the posted values but was not extended for the diff behaviour. Classification: PASS on the pattern, with the `install.pl` gap called out for action.

### F3.9 - Known-flaky test de-flaked (FIXED, was PASS-with-note)

`t/unit/auth/03-login-rate-limit.t` now guards the 300-second window rollover: if the current time is within 8 seconds of the boundary, the test sleeps past it before seeding, eliminating the sub-1% spurious failure the prior review traced. The unconditional failing-test refusal can no longer fire spuriously from this file.

### F3.10 - Evidence and tracking currency (WARN, minor)

- `docs/architecture/test-coverage.md` records the 2026-07-02 measurement and totals ("2048 tests across 141 files") - one cycle stale against today's 2504/162 and the fresh per-CGI numbers above; its note about a remaining `TODO` in `04-edge-cases.t` is also stale (fixed).
- The floor file names "the subprocess-coverage-stability work (backlog)" as the real fix for the manager-api branch variance, but no such item exists in `docs/feature-requests/BACKLOG.md` - the residual is tracked only inside a config-file comment.

## Prior findings - disposition

```datatable
columns: Prior finding (v0.5.35) | Disposition at v0.6.10
widths: 7cm | X
bold: 1
tone: light
---
F3.3 statement-only threshold, no branch floor | FIXED - branch_floor=60 declared and enforced, per-file override mechanism documented
F3.4 recorded coverage evidence stale | FIXED - gate runs on every release; fresh full measurement taken at this tag
F3.5 coverage gate not wired into release.sh | FIXED - runs in release.sh; a floor breach refuses the release
F3.6 lazysite-auth.pl outside the gate; Plugins/Upload under-measured | FIXED - auth gated at 82.1/62.5 via env_passthrough(); Plugins 21% to 66%, Upload 37% to 82% (measurement artefact resolved). install.pl remains outside (documented); mcp/oauth are a NEW scope gap (F3.6 above)
F3.7 login rate-limit flake | FIXED - sleep-past-rollover guard; window computed once
```

## Recommendations

1. Make "not measured" a gate failure: in `tools/coverage.sh --check`, set `fail=1` in the empty-`$pct` branch (keeping the message). The project's own history shows unmeasured-but-gated is a real, weeks-long failure mode; this converts it into a refusal. Where: `tools/coverage.sh`. Effort: S. Satisfies: fail-closed gate integrity (F3.7).
2. Add `lazysite-mcp.pl` and `lazysite-oauth.pl` to the gate list. mcp passes today; oauth needs targeted branch tests (58.9% against the 60% floor) before it can join without an override - add the tests rather than an override, since the shortfall is real coverage, not measurement noise. Where: `tools/coverage.sh` CGI list, `t/unit/oauth/`. Effort: M. Satisfies: gate scope matches the production surface (F3.6).
3. Ratchet the enforced floors toward the measured reality: every gated CGI measures 79.5%+ statements, so raise `floor` to 75 (meeting the Commercial regime floor by enforcement, not just in fact) and `branch_floor` to 62; keep the manager-api per-file branch override at 60 until the variance work lands. Where: `dist/config/coverage-floor`. Effort: S. Satisfies: the regime's 75% floor becomes the refusal threshold (F3.4).
4. Pin the 0.6.6 `install.pl` ownership-scoping fix: a root-skippable test asserting the repair touches only root-owned paths and never re-owns CGI runtime files - `t/tools/03-install-pl.t` already has the harness. Effort: M. Satisfies: the twice-field-hit path gets a regression pin (F3.8).
5. Record the subprocess-coverage-stability work as a proper backlog item in `docs/feature-requests/BACKLOG.md` (currently referenced only from a comment in the floor file). Effort: S. Satisfies: the residual survives outside config comments (F3.10).
6. Refresh `docs/architecture/test-coverage.md`: suite totals (2504/162), today's per-CGI baseline, drop the stale `TODO` note, and note the mcp/oauth gate additions when recommendation 2 lands. Effort: S. Satisfies: Dimension 7 currency of the coverage evidence (F3.10).
