---
title: "Dimension 3 - Test coverage - lazysite eight-dimension review"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime"
brand: plain
---

## Verdict

WARN - the full suite runs green (139 files, 2003 tests, 163 s) and a declared statement-coverage floor with a recorded above-floor measurement exists, but the coverage gate is not wired into `tools/release.sh`, no branch threshold is declared anywhere despite the framework demanding line and branch thresholds, and the recorded measurement is dated 2026-06-24 - before the entire 0.5.x line (roughly 35 edge releases, including the SM095 capability rework).

## Method

Assessed at tag `v0.5.35`, commit `de12238` (tree verified clean apart from this review directory). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 3 detail ("the test suite runs, passes, and meets the line- and branch-coverage thresholds the regime sets") and the by-design prevention catalogue ("a coverage-threshold breach refuses the release ... a failing test in the suite refuses the release unconditionally"). Commands run:

- `find t/ -name '*.t'` inventory, counted by area.
- `prove -lr t/` - the full suite, run to completion.
- Read `dist/config/coverage-floor`, `docs/architecture/test-coverage.md`, `tools/coverage.sh`, `tools/release.sh`; `git log --follow` on the config files.
- Coverage instrumentation probe: `prove -l t/unit/dav/` plain versus under `PERL5OPT=-MDevel::Cover=...` (the exact mechanism `tools/coverage.sh` uses), to estimate the full-run cost against the review time box.
- `t/unit/auth/03-login-rate-limit.t` executed five consecutive times via a scripted loop.

## Findings

### F3.1 - Suite inventory (PASS)

139 `.t` files under `t/`:

```datatable
columns: Area | Files | Content
widths: 3.5cm | 1.5cm | X
bold: 1
tone: light
---
t/unit/ | 109 | processor, auth, dav, manager, users, forms, plugins function-level tests
t/integration/ | 15 | render pipeline, cache hit, auth flow, preview, DAV publish
t/journey/ | 5 | multi-step scenarios (site setup, auth, forms, edge cases, WebDAV lifecycle)
t/tools/ | 5 | manifest, SBOM, bundle-apply, install.pl, check
t/lint/ | 3 | stale paths, perlcritic, secrets
t/smoke/ | 1 | every starter page renders
t/run-all.t | 1 | aggregate runner (skipped under prove -r)
```

Minor drift: the overview table in `docs/architecture/test-coverage.md` still says "1034 tests across 75 files" - roughly half the current suite. A Dimension 7 matter, noted here for the docs assessor.

### F3.2 - Full suite green (PASS)

`prove -lr t/` at `de12238`:

```text
All tests successful.
Files=139, Tests=2003, 163 wallclock secs (0.47 usr 0.15 sys + 111.27 cusr 13.26 csys = 125.15 CPU)
Result: PASS
```

2003 of 2003 assertions pass. The framework's unconditional refusal condition (a failing test) is not triggered.

### F3.3 - Declared thresholds exist, statement-only (WARN)

`dist/config/coverage-floor` declares `floor=60` (enforced regression floor, statements, per cleanly-measured production CGI) and `target=75` (the Commercial regime target). `tools/coverage.sh --check` enforces the floor against five CGIs (`lazysite-dav.pl`, `lazysite-processor.pl`, `lazysite-manager-api.pl`, `tools/lazysite-users.pl`, `tools/lazysite-bundle-apply.pl`).

The framework demands "line- **and branch**-coverage thresholds". No branch threshold is declared anywhere: `coverage-floor` carries branch percentages only as commentary (49-92% across components at the last measurement), and the `--check` gate compares the statement column alone. Classification: WARN - a framework non-conformance in the declaration itself, independent of any measured number.

### F3.4 - Coverage not re-measured in this review; recorded evidence is stale (WARN)

The full instrumented run was not executed. Probe evidence: `t/unit/dav/` takes 28 s plain and 130 s under the same `PERL5OPT` Devel::Cover instrumentation `tools/coverage.sh` uses - a 4.6x slowdown. Extrapolated over the 163 s full suite that is roughly 12.5 minutes plus the `cover` merge across hundreds of subprocess runs, which exceeds the review's 8-minute time box. No coverage numbers in this report are freshly measured; the classification below rests on recorded evidence:

- `dist/config/coverage-floor` and `docs/architecture/test-coverage.md` record a full subprocess-instrumented measurement dated 2026-06-24 (post-SM079): gated CGIs at 68-93% statements / 65-74% branches, all above the 60% floor, `lazysite-manager-api.pl` at 68% the closest to it.
- `CHANGELOG.md` (0.4.0 QC close-out, 2026-06-24): "1416 tests green ... `tools/bench.pl --check` and `tools/coverage.sh --check` floors hold".

That measurement predates the whole 0.5.x line - v0.5.35 is roughly 35 edge releases later and includes the SM095 capability rework, the users-page endpoint, sections, provenance stamping and more. The suite has grown from 1416 to 2003 assertions in the same period, so coverage has plausibly held or improved, but "plausibly" is not a measurement. Classification: WARN - threshold and gate exist and the last measurement passed, but the evidence is a week and a minor-version line old.

### F3.5 - Coverage gate not wired into release.sh (WARN)

`tools/release.sh` runs `prove -r` and the SBOM strictness gate (`manifest-to-sbom.pl --strict`) only - confirmed by grep; there is no invocation of `tools/coverage.sh`. The framework's by-design prevention for this dimension is "a coverage-threshold breach **refuses the release**, not a reminder"; today the gate is a by-hand signoff tool that nothing forces anyone to run, which is how F3.4's staleness arose. Classification: WARN under the Commercial regime - the artefacts exist but the refusal is not wired.

### F3.6 - Gate scope excludes the login endpoint (WARN)

The `--check` loop gates five CGIs. `lazysite-auth.pl` - the credential-handling login endpoint - and `install.pl` are outside the gate (the script comments record the reason: their tests run them from tempdir copies, splitting the measurement). `Lazysite::Manager::Plugins` (21% stmt) and `Manager::Upload` (37%) are documented as measurement artefacts of subprocess-only testing rather than test gaps, with the fix already identified (in-process handler tests, as `Themes` does). Classification: WARN - the most security-sensitive CGI has no coverage floor at all, even though its behaviour is well exercised by `t/unit/auth/` and the journey tests.

### F3.7 - Known-flaky test: 0/5 failures observed (PASS, with a note)

`t/unit/auth/03-login-rate-limit.t` run five consecutive times: 5 passes, 0 failures. The flake mechanism is visible in the source: the test seeds the `DB_File` counter under the key `"$ip:" . int(time()/300)` and then makes a real CGI request; if the 300-second window rolls over between the seed and the request, the seeded counter lands in an expired window and the boundary assertions fail. With well under a second between seed and request, the per-run failure probability is below about 1% - consistent with 5/5 green here while still being observed occasionally. Under the framework a spurious failure refuses a release unconditionally, so the flake is a release-pipeline hazard, not just an annoyance. Classification: PASS on observed behaviour, with the de-flake recommended below.

## Recommendations

1. Wire `tools/coverage.sh --check` into `tools/release.sh` after the `prove` step. The ~13-minute instrumented run is acceptable at release cadence, and it converts F3.4's staleness from a standing condition into an impossibility. Where: `tools/release.sh`, staged tree, before the SBOM gate. Effort: S. Satisfies: the by-design coverage refusal the Commercial regime expects.
2. Declare and enforce a branch floor. Add `branch_floor=60` to `dist/config/coverage-floor` (all five gated CGIs measured 65-74% branches, so 60 is a safe ratchet start) and extend the `awk` comparison in `tools/coverage.sh --check` to read the `bran` column as well as `stmt`. Effort: S. Satisfies: the framework's line-and-branch threshold requirement (F3.3).
3. Re-measure at v0.5.35 and refresh the recorded baseline in `dist/config/coverage-floor` and `docs/architecture/test-coverage.md` (one instrumented run plus a doc edit), ratcheting the floor if the numbers allow. Effort: S. Satisfies: current evidence for F3.4 until recommendation 1 lands.
4. Bring `lazysite-auth.pl` into the gate: either resolve the tempdir-copy measurement split (run the CGI from the repo path with `DOCUMENT_ROOT` pointing at the tempdir, as the DAV tests do) or add in-process unit tests for its extracted logic. Where: `t/unit/auth/`, `tools/coverage.sh` CGI list. Effort: M. Satisfies: coverage floor on the credential path (F3.6).
5. Add in-process unit tests calling `Manager::Plugins` and `Manager::Upload` `action_*` handlers as module functions - the step `docs/architecture/test-coverage.md` already names - raising true measured coverage toward the 75% target. Effort: M. Satisfies: the Commercial 75% target trajectory.
6. De-flake `03-login-rate-limit.t`: compute `int(time()/300)` once, and if the window boundary is within a few seconds, sleep past it before seeding (or seed both adjacent windows). Where: the test's `seed_count`. Effort: S. Satisfies: the unconditional failing-test refusal cannot fire spuriously (F3.7).
7. Correct the stale suite totals in `docs/architecture/test-coverage.md` (1034/75 to 2003/139) when touching it for recommendation 3. Effort: S. Satisfies: Dimension 7 currency.
