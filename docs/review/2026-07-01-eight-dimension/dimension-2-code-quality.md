---
title: "Dimension 2 - Code quality - lazysite eight-dimension review"
subtitle: "v0.5.35 (de12238), 2026-07-01, Commercial regime"
brand: plain
---

## Verdict

WARN - the project's own gate (curated `.perlcriticrc` at severity 4, enforced by `t/lint/02-perlcritic.t`) passes with zero violations across all 36 production files, but the framework's stated bar for Perl is perlcritic severity 3 plus `perltidy --check`: severity 3 currently carries 1,518 violations (79 per cent of them one policy) and the project has no perltidy configuration or tidy gate at all.

## Method

Assessed at tag `v0.5.35`, commit `de12238`. File set: `*.pl` (repo root), `tools/*.pl`, `plugins/*.pl`, `lib/Lazysite/**/*.pm` - 36 files, 11,721 lines across the six main scripts alone. Commands run:

- `perlcritic --profile .perlcriticrc --quiet <36 files>` - the project gate, severity 4.
- `perlcritic -3 --profile .perlcriticrc` with `--verbose '%p|%f|%l'` and `--statistics-only`, tallied by policy and by file (the tighten-to-3 delta with the curated exclusions retained).
- `perlcritic -3 --noprofile --statistics-only` for the raw comparison.
- `find` for `.perltidyrc`/`.tidyallrc` (none); `which perltidy` (installed, `/usr/bin/perltidy`).
- Dead-code spot-check: the eight `Subroutines::ProhibitUnusedPrivateSubroutines` hits cross-checked with repo-wide greps for each flagged sub; plus a best-effort in-file scan of the three largest scripts counting references to every defined sub (a sub whose name appears only at its definition is a dead-code candidate).

## Findings

### F2.1 - Project gate clean (PASS)

`perlcritic --profile .perlcriticrc --quiet` over all 36 files produced no output (exit 0): zero violations at the curated severity 4. This matches the `t/lint/02-perlcritic.t` gate and the claim in `docs/architecture/code-quality.md`. Each disabled policy in `.perlcriticrc` carries a written rationale in the profile and a fuller one in the architecture doc - the curation is documented, not silent suppression.

### F2.2 - Severity-3 delta: 1,518 violations (WARN)

The framework's Perl tooling line is "perlcritic at severity 3 with the shared profile", and its by-design pattern makes a severity-3 violation refuse the build. `docs/architecture/code-quality.md` itself calls tightening to 3 "future work". Quantified with the project's own exclusions retained (`perlcritic -3 --profile .perlcriticrc`):

```datatable
columns: Count | Policy | Character of the fix
widths: 1.8cm | 8cm | X
bold: 2
tone: medium
text: 3
---
1,197 | RegularExpressions::RequireExtendedFormatting | Mechanical /x sweep, or a documented profile exclusion (the architecture doc already argues the deviation)
84 | Variables::RequireInitializationForLocalVars | Mechanical: initialise each `local our` / `local $x`
43 | Subroutines::ProhibitExcessComplexity | Real refactoring; hotspots are tools/lazysite-users.pl and lazysite-processor.pl (8 subs each)
42 | Variables::ProhibitPackageVars | Structural: the lib modules use `our $DOCROOT`-style context injection by design
20 | ControlStructures::ProhibitCascadingIfElse | Dispatch-table refactors in the CGI action routers
16 | Variables::ProhibitReusedNames | Small renames
14 | RegularExpressions::ProhibitCaptureWithoutTest | Guard each capture use |
13 | ErrorHandling::RequireCheckingReturnValueOfEval | Genuine robustness fixes |
89 | Fourteen further policies (12 or fewer hits each) | Mixed; includes 6 RequireCheckedOpen and 9 ProhibitBacktickOperators worth real attention
```

Total: 1,518 severity-3 violations across the 36 files (top files: `lazysite-processor.pl` 326, `lazysite-mcp.pl` 131, `lazysite-dav.pl` 96, `lazysite-manager-api.pl` 94). One policy - `RequireExtendedFormatting` - accounts for 79 per cent; excluding it the way the architecture doc already argues would leave 321 violations, of which roughly half are mechanical. The raw no-profile run additionally shows 216 severity-5 and 205 severity-4 hits, confirming the curated exclusions are doing real (documented) work. Classification: WARN - the project gate is honest and green, but the regime's stated bar is severity 3 and the gap is quantified, not closed.

### F2.3 - No perltidy configuration or gate (WARN)

The framework requires `perltidy --check` alongside perlcritic. There is no `.perltidyrc` or `.tidyallrc` anywhere in the repo, no tidy gate in `t/lint/`, and `docs/architecture/code-quality.md` does not mention formatting enforcement (perltidy itself is installed on the host). The codebase is visually consistent by convention, but nothing pins it: a divergently formatted contribution would pass every existing gate. Classification: WARN - a declared-tooling gap against the regime.

### F2.4 - Stale counts in the code-quality doc (WARN, low)

`docs/architecture/code-quality.md` cites "~485 hits" for `RequireExtendedFormatting`, "~119" for `RequireFinalReturn` and "~53" for `ProhibitExplicitReturnUndef`; current measurements are 1,197, 127 and (raw profile) within the 216 severity-5 block respectively. The rationale still holds; the numbers no longer do. Also stale in the same doc: the script inventory omits `lazysite-mcp.pl`, `lazysite-oauth.pl` and `plugins/stats.pl`, and the "No shared modules" policy statement contradicts the 15-module `lib/` tree (raised as a groundedness finding in the Dimension 1 report, F1.4).

### F2.5 - Dead code: one confirmed sub; the lint signal is mostly export false-positives (WARN, low)

Of the eight `ProhibitUnusedPrivateSubroutines` hits, seven are underscore-named subs that are exported through `@EXPORT_OK` and used cross-module (`_artifact_dir`, `_artifact_digest`, `_write_conf_key`, `_reset_upload_limits_cache`, `_to_list`, `_acl_denied`, `_consume_lock`) - the policy cannot see exports, and the real smell is exporting underscore-"private" names as a public interface. One is genuinely dead: `_user_analytics` at `lazysite-manager-api.pl:1201`, defined and never called repo-wide (detail in the Dimension 1 report, F1.7). The in-file reference scan of the three largest scripts (`lazysite-processor.pl`, `lazysite-auth.pl`, `lazysite-mcp.pl`) found no sub referenced only at its definition. Method note: grep-based, so string-dispatched calls would be missed; the CGIs dispatch through explicit `elsif` chains and code-ref tables, which the scan does count.

### F2.6 - Dead complexity indicators (observation)

43 subs exceed the McCabe threshold at severity 3 (`ProhibitExcessComplexity`), concentrated in `tools/lazysite-users.pl` (8) and `lazysite-processor.pl` (8), plus 9 `ProhibitExcessMainComplexity` hits - consistent with the self-contained-CGI style, where each script's main dispatch absorbs what a framework would factor out. Not dead code, but the complexity budget the severity-3 decision has to price in.

## Recommendations

1. Add a `.perltidyrc` and a `t/lint/05-tidy.t` gate (run `perltidy -st` per file and fail on any diff against the source), seeded from the codebase's current de-facto style so the initial run is near-clean. Effort M (one-off reformat churn is the cost; do it in a dedicated commit). Satisfies the framework's `perltidy --check` requirement (F2.3).
2. Decide `RequireExtendedFormatting` explicitly: either add it to `.perlcriticrc`'s documented exclusions (the architecture doc already contains the argument) or run the /x sweep. This one decision removes 1,197 of 1,518 severity-3 violations and makes the remaining 321 a tractable burn-down list. Effort S (exclude) or L (sweep). Prerequisite for recommendation 3.
3. Burn down the mechanical severity-3 remainder (84 local-var initialisations, 16 renames, 14 capture guards, 13 eval checks, 6 checked opens) and then raise the `.perlcriticrc` severity to 3 with the surviving exclusions documented, updating `t/lint/02-perlcritic.t`'s comment. Effort M. Brings the project gate to the framework's stated Perl bar (F2.2) and converts "future work" into the by-design refusal the Commercial regime expects.
4. Refresh `docs/architecture/code-quality.md`: current violation counts, complete script inventory, and replace the "No shared modules" policy with the actual rule (shared `lib/`, module-free processor render path). Effort S. Clears F2.4 and the doc side of Dimension 1's F1.4.
5. Remove `_user_analytics` (`lazysite-manager-api.pl:1201`) and consider renaming the cross-module-exported underscore subs (or documenting the convention) so `ProhibitUnusedPrivateSubroutines` becomes a clean dead-code signal instead of seven-eighths noise. Effort S. Clears F2.5.
6. Schedule the complexity hotspots (the 8 + 8 subs in `tools/lazysite-users.pl` and `lazysite-processor.pl`) for dispatch-table refactors as they are next touched, rather than as a big-bang rewrite. Effort L spread over time. Reduces the severity-3 residue that cannot be fixed mechanically (F2.6).
