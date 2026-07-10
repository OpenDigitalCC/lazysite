---
title: "Dimension 2 - Code quality - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

PASS - the two gaps the prior review warned on are both closed and mechanically enforced: the project profile now runs at the framework's stated severity 3 with zero violations across 47 production files (19,452 lines), and a calibrated `.perltidyrc` plus the changed-code tidy gate are wired into the same unskippable release path as the compile, security-lint, coverage, bench and SBOM gates. No lint violation can ship. The residual findings - no shellcheck gate over the five shipped bash scripts, lint gates that silently skip when their tool is absent from the release host, one vacuous check inside the secrets gate, and small doc-count staleness - are each S-effort hardening, and none currently masks a shipped violation (shellcheck at `-S error` and the corrected secrets grep were both run by hand and are clean).

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (clean working tree verified). File set: `*.pl` (repo root), `tools/*.pl`, `plugins/*.pl`, `lib/Lazysite/**/*.pm` - 47 files (36 at the prior review; the growth is the SM136/SM140-era modules and plugins), 19,452 lines of Perl code. Prior review: `docs/review/2026-07-01-eight-dimension/dimension-2-code-quality.md` (v0.5.35). Commands run:

- `prove -l t/lint/` - all six gates green (63 tests): stale-paths, perlcritic (severity 3), secrets, compile, perlcritic security theme, tidy.
- `perlcritic --profile .perlcriticrc --quiet --statistics-only <47 files>` - the project gate: 0 violations, average McCabe 7.37.
- `perlcritic -3 --noprofile --statistics-only` - the raw framework-bar comparison, tallied by policy (saved to scratch).
- `perl tools/tidy-check.pl` at the tag, and `--base v0.6.7` / `--base v0.6.4` to exercise the gate against real code deltas (the 0.6.5–0.6.10 changes); `tools/release.sh` and `Makefile` read for gate wiring.
- `shellcheck -S error install.sh tools/release.sh tools/coverage.sh tools/build-static.sh tools/commit.sh` - clean, exit 0.
- Module-boundary spot-checks of the ADR 0001 local copies (SM138's `_site_grants_manager`, SM140's recorder, the lazy `Lazysite::Fetch` require); a grep-based dead-code scan over all 694 defined subs.

## Prior findings - status

```datatable
columns: Prior finding | Status | Evidence
widths: 6cm | 2.6cm | X
bold: 2
tone: medium
text: 3
---
F2.2 severity-3 delta of 1,518 violations | FIXED | `.perlcriticrc` set to `severity = 3` (0.5.40); gate green with zero violations; the move fixed genuine findings (unchecked opens, unused captures) whose policies stay enabled
F2.3 no perltidy configuration or gate | FIXED | `.perltidyrc` calibrated to the house style (newlines frozen); `tools/tidy-check.pl` + `t/lint/06-tidy.t`, changed-code-only (0.5.40); exercised here against real deltas
F2.4 stale counts and inventory in code-quality.md | LARGELY FIXED | Inventory now complete (incl. mcp, oauth, stats); shared-`lib/` policy stated correctly; residual staleness in two counts and one phrase - see F2.7
F2.5 dead `_user_analytics`; misleading unused-sub signal | RESOLVED BY DECISION | The sub is gone; `ProhibitUnusedPrivateSubroutines` is excluded with a written rationale (exported `_`-subs) rather than the suggested rename - the deviation is documented, at the cost of the dead-code signal
F2.6 complexity hotspots (43 subs over threshold) | OPEN BY DECISION | The complexity policies are excluded as documented house convention rather than burned down; raw over-threshold subs now 48. `code-quality.md` still names the dispatchers "a refactor candidate for a future cycle"
```

## Findings

### F2.1 - Project gate green at the framework bar (PASS)

`perlcritic --profile .perlcriticrc` over all 47 production files: 0 violations at severity 3 (the profile's declared level), matching the `t/lint/02-perlcritic.t` gate and the claim in `docs/architecture/code-quality.md`. The security theme runs separately at severity 1 (`t/lint/05-perlcritic-security.t`, also zero). The prior review's WARN basis - a stated bar of severity 3 against a project gate at 4 - no longer exists: the project bar and the framework bar are the same number, and the by-design refusal (a severity-3 violation refuses the build) is real, because the gate runs inside the release path's `prove -r t/`.

### F2.2 - What the curated profile absorbs (characterisation)

The raw no-profile run at severity 3 shows 2,085 hits (236 severity 5, 214 severity 4, 1,635 severity 3) absorbed by 31 policy deviations, each carrying a written rationale in `.perlcriticrc` and a fuller one in `docs/architecture/code-quality.md`. The absorption is curation, not suppression - but its shape is worth recording:

```datatable
columns: Raw hits | Policy | How the profile handles it
widths: 1.8cm | 7.5cm | X
bold: 2
tone: medium
text: 3
---
1,283 | RegularExpressions::RequireExtendedFormatting | Enabled with a 60-character threshold - complex patterns must carry `/x`, short ones stay clean; the decision the prior review asked for, taken and documented
127 | Subroutines::RequireFinalReturn | Excluded - last-expression returns are the house shape
100 | InputOutput::RequireEncodingWithUTF8Layer | Excluded - `:utf8` chosen over `:encoding(UTF-8)` so legacy content renders instead of 500ing; JSON auth files documented as the raw-octets exception (ADR 0001)
99 | Subroutines::ProhibitExplicitReturnUndef | Excluded - `return undef` is the scalar-context idiom, argued in the doc
97 | Variables::RequireInitializationForLocalVars | Excluded - the `local $/;` slurp idiom
48 | Subroutines::ProhibitExcessComplexity | Excluded - the if/elsif dispatchers are a documented, tested design (see F2.6)
331 | Twenty-five further policies | Mixed exclusions, each with a one-line rationale in the profile
```

The genuine severity-3 findings the 0.5.40 move surfaced (unchecked `open`s, captures made non-capturing) were fixed, and those policies remain enabled to guard future code - the honest half of a tighten-the-bar exercise, verifiable in the profile's header comment.

### F2.3 - Tidy gate: present, calibrated, wired, and exercised (PASS)

`.perltidyrc` freezes newlines so `tools/tidy-check.pl` can compare line-by-line; the gate flags only lines a change touched since the last release tag, so the legacy tree keeps its hand-formatting while new and edited code must be tidy. Posture verified three ways: at the tag it reports "no changed production files" (tree equals tag - correct); against `--base v0.6.7` and `--base v0.6.4` (real code deltas including the SM140 recorder and the SM138 retirement) it reports all touched lines tidy; and it is wired into the release path, because `t/lint/06-tidy.t` runs inside `release.sh`'s staging-clone `prove -r t/`, where the fresh clone's latest tag is the previous release - so the gate covers exactly the delta being shipped, including files that were untracked during the session. Whole-tree tidy drift remains known and accepted; the gate is the right shape for that decision.

### F2.4 - Gate wiring in the release path (PASS, two soft spots)

`tools/release.sh` runs, in order and each with an explicit refusal: the full suite (`prove -r t/`, which carries all six lint gates), `bench.pl --check`, `coverage.sh --check`, the manifest build, and `manifest-to-sbom.pl --strict` - before any tarball, tag or push. Nothing in the path is optional or flag-skippable; `Makefile` offers the same `prove` targets for development. Two soft spots against the "unskippable" ideal:

- `t/lint/02-perlcritic.t` and `06-tidy.t` `skip_all` when their tool is absent from the host (a deliberate courtesy for release-tarball consumers). On the team's release host both tools are installed, but a release cut from a minimal host would silently lose the code-quality gates - the skip prints a reason, yet `prove` stays green.
- The committed secrets gate (`t/lint/03-secrets.t`) contains a check that has never run - the private-key pattern is parsed by `git grep` as an option and the test passes on the empty output of a command that failed to start. Owned by the Dimension 1 report (F1.4, `invalid-test`); noted here because it is a gate-quality defect a planted-fixture self-test would have caught. The corrected grep, run by hand with the gate's own exclusions, finds nothing - no violation ships.

### F2.5 - No shellcheck gate over shipped bash (WARN)

The framework's per-language line for this dimension is `shellcheck -S error` on every shipped script, listed among the by-design refusals. The project ships five bash scripts (`install.sh`, `tools/release.sh`, `tools/coverage.sh`, `tools/build-static.sh`, `tools/commit.sh`); run by hand at `-S error` they are clean, but no gate exists in `t/lint/` or anywhere in the release path, so a known-bad construct in the installer would ship. Classification: WARN - the last declared-tooling gap in this dimension, and an S-effort one given the clean baseline.

### F2.6 - Module boundaries hold; complexity remains open by decision (PASS / observation)

The ADR 0001 discipline was spot-checked at every site the review window created: the processor's SM138 copy (`_site_grants_manager`) is marked with the ADR reference and semantically in sync with `Settings::site_grants_manager`; the SM140 recorder is explicitly annotated "Module-free per ADR 0001"; the lazy `require Lazysite::Fetch` on the `.url` path carries the same reference. The boundary miss of the window - six private `user-settings.json` readers in `lazysite-auth.pl` duplicating an imported module's reader with a material encoding difference - is owned by Dimension 1 (F1.3) as the correctness finding it is; from this dimension's side it is the reminder that conceptual duplication does not show up in any lint signal the project runs.

On complexity: rather than the prior review's suggested burn-down, the three complexity policies were excluded as documented house convention ("documented, tested if/elsif dispatchers"), and the raw count of over-threshold subs has grown 43 to 48 with the window's features. The exclusion is argued in the profile and the architecture doc, which still names the dispatchers a refactor candidate - a consistent, honest position, but a profile comment is a weaker record than the framework's deliberate-keep ADR shape for a decision a future refactor (human or agent) should not silently revisit.

### F2.7 - Dead code and comment discipline (WARN, low)

The dead-code scan (694 subs, production + test trees) found exactly one orphan: `_has_settings_entry` (`tools/lazysite-users.pl:2176`), stranded by the SM138 commit `f3a712a` - the same class as the prior review's `_user_analytics`, and the same trivial removal. Comment discipline is otherwise a strength - implementation comments cite SM numbers, ADRs and field incidents, and the tests' header comments state what they pin and why - with a short stale list: the "Phase 1 keeps both working" / SM095-era comments on the legacy conf union (`tools/lazysite-users.pl:2056–2059, 2191–2198`), the "single duplicated helper" phrase in `code-quality.md:16`, and two drifted counts in the same doc's deviation table ("~53 hits" for `ProhibitExplicitReturnUndef` against a current raw 99; "~90" for `RequireEncodingWithUTF8Layer` against 100). The rationales still hold; the numbers and the singular no longer do.

## Recommendations

1. Add `t/lint/07-shellcheck.t` running `shellcheck -S error` over `install.sh` and `tools/*.sh`, skip-if-absent like its siblings. Effort S. Closes the last declared-tooling gap (F2.5) from a clean baseline.
2. Give the lint gates a self-test: fix the secrets gate's `-e` flag and add a planted-fixture check proving each gate can fail (a deliberately untidy line, a fake key header, a severity-3 violation in a fixture file). Effort S. Converts gate QA from assumed to demonstrated (F2.4).
3. Make tool-absent skips visible at release: have `release.sh` assert `perlcritic`, `perltidy` (and `shellcheck` once gated) exist before running the suite, so a minimal release host refuses loudly instead of skipping silently. Effort S. Hardens the unskippable property the regime expects (F2.4).
4. Refresh the residual staleness in `docs/architecture/code-quality.md` (99 not ~53, 100 not ~90, two marked processor copies not one) and delete `_has_settings_entry` plus the Phase-1 comments while there. Effort S. Clears F2.7 and the doc side of Dimension 1's F1.6/F1.7.
5. Record the dispatcher complexity exclusion as a deliberate-keep ADR (context: the self-contained CGI dispatch style; consequence: the excluded policies and the 48-sub residue), or schedule the two hotspot files for dispatch-table refactors as they are next touched. Effort S (ADR) or L spread over time (refactor). Converts F2.6 from open-by-convention to recorded-by-decision.
