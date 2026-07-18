---
title: "Dimension 3 - Test coverage - lazysite eight-dimension review"
subtitle: "v0.7.28 (6780878), 0.8.0-stable candidate, 2026-07-18, Commercial regime"
brand: plain
---

# Verdict

PASS - the two open items the prior review left (F3.6 gate scope, F3.7 fail-open
"not measured") are both closed in the gate itself: `lazysite-mcp.pl` and
`lazysite-oauth.pl` are now in the `tools/coverage.sh --check` CGI list, and an
unmeasured gated CGI now sets `fail=1` rather than skipping silently. All eight
production CGIs are gated and measure above the declared 75%/62% floors (with the
three documented per-file branch overrides at 60 still live). The full suite is
green (4179 tests). The material new work since 0.7.0 - `Lazysite::Lang`,
`Lazysite::I18n`, `Lazysite::Auth::DomainAccess` (SM179 / SM165), the domains
manager surface, and the conf-mtime cache-invalidation fix - each lands with
same-commit tests that pin the branches and the security-relevant edge cases, not
just the happy path. The residual is documentation currency, not gate integrity:
`docs/architecture/test-coverage.md` still records the 2026-07-02 baseline
(2048 tests / 141 files) against today's 4179 / 232, one cycle stale - a
Dimension 7 carry, not a Dimension 3 refusal.

# Method

Assessed at tag `v0.7.28`, commit `6780878` (working tree equals the tag).
Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`, Dimension 3 detail
("the test suite runs, passes, and meets the line- and branch-coverage
thresholds the regime sets"; Commercial coverage floor 75%) and the by-design
prevention catalogue ("a coverage-threshold breach refuses the release, not a
reminder ... a failing test in the suite refuses the release unconditionally").
Prior review: `docs/review/2026-07-10-eight-dimension/dimension-3-test-coverage.md`
(v0.6.10, WARN), each finding re-verified. Work examined:

- Read `tools/coverage.sh` and `dist/config/coverage-floor` in full, confirming
  the gate CGI list and the fail-closed behaviour line by line.
- Read the new modules `lib/Lazysite/Lang.pm`, `lib/Lazysite/I18n.pm`,
  `lib/Lazysite/Auth/DomainAccess.pm` and their unit tests
  `t/unit/lib/40-lang.t`, `t/unit/lib/41-i18n.t`, `t/unit/lib/20-domain-access.t`.
- Read the conf-mtime cache path (`try_serve_cache`, `resolve_site_vars` in
  `lazysite-processor.pl`) and its integration test
  `t/integration/25-conf-cache-invalidation.t`.
- Inventoried the SM179/SM165 test surface (`find t/`): 20 new lang/i18n/domain
  test files across unit, integration, manager and mcp tiers.
- The **full instrumented coverage run was NOT re-executed** (~15-20 minutes);
  the per-CGI figures below are the current mechanical results supplied for this
  review, consistent with the floor file's recorded baseline.
- The full plain suite was **not** re-run; the supplied mechanical result
  (`prove -lr t/` = 4179 tests pass) is cited. Note: no per-release suite log for
  0.7.28 was found under `/srv/tmp/sm-test/` (the series stops at rel711); the
  4179-pass figure is taken as the review input, not re-derived from a log.

# Findings

## F3.1 - Suite inventory and growth (PASS)

232 `.t` files under `t/` (was 162 at v0.6.10; +43% file count), 4179 assertions
(was 2504). The growth tracks the 0.7.x feature line - multilingual (SM179),
domain access (SM165), the domains manager UX - and every new subsystem below
carries its own test files. The lint tier (compile sweep, security perlcritic,
tidy, stale-path, secrets) still runs under `prove`, so it stays inside the
release gate.

## F3.2 - Full suite green at candidate (PASS)

The supplied mechanical result at `6780878` is `prove -lr t/` = 4179 tests pass.
The framework's unconditional refusal condition (a failing test) is not
triggered, and it stays mechanically enforced: `tools/release.sh` runs
`prove -r "$STAGE/t/"` on the staged tree and refuses on any failure
(`tools/release.sh:215`). One evidence gap: unlike prior cuts, no
`rel728-*suite*.log` exists under `/srv/tmp/sm-test/`, so the pass is taken from
the review brief rather than a retained release log - see recommendation 4.

## F3.3 - Gate scope now matches the production surface (FIXED, was WARN F3.6)

The prior review's headline WARN was that `lazysite-mcp.pl` and
`lazysite-oauth.pl` were measured but ungated, and oauth's 58.9% branches would
fail the floor if gated. Both are now in the gate. `tools/coverage.sh:43-45`:

```
for f in lazysite-dav.pl lazysite-processor.pl lazysite-manager-api.pl \
         lazysite-auth.pl lazysite-mcp.pl lazysite-oauth.pl \
         tools/lazysite-users.pl tools/lazysite-bundle-apply.pl; do
```

All eight production CGIs are gated. oauth's shortfall was closed with real
coverage (`t/unit/oauth/03-branches.t`, 234 lines; the floor file records the
targeted run at 99.3/94.6). Current mechanical figures, all above floor:

```datatable
columns: Gated CGI | stmt | bran | Floor (branch override) | Result
widths: 6cm | 1.6cm | 1.6cm | 3cm | X
bold: 1
tone: light
---
lazysite-dav.pl | 93.6% | 72.9% | 75/62 | ok
lazysite-oauth.pl | 99.3% | 94.6% | 75/62 | ok
lazysite-mcp.pl | 90.0% | 62.8% | 75/62 (60) | ok
tools/lazysite-users.pl | 89.5% | 71.3% | 75/62 | ok
tools/lazysite-bundle-apply.pl | 89.8% | 65.0% | 75/62 | ok
lazysite-processor.pl | 86.4% | 71.6% | 75/62 | ok
lazysite-auth.pl | 83.3% | 64.8% | 75/62 (60) | ok
lazysite-manager-api.pl | 78.7% | 62.8% | 75/62 (60) | ok
```

Only `install.pl` remains outside the gate, and that exclusion is documented in
both the gate script (`tools/coverage.sh:38-40`) and the floor file - its tests
exercise a tempdir-copied tree end to end, so `cover` cannot attribute the child.
The prior review's undocumented scope gap is closed.

## F3.4 - Gate integrity: "not measured" is now a refusal (FIXED, was WARN F3.7)

The prior review's F3.7 - a gated CGI whose report row was absent printed
`not measured` and `continue`d without failing - is fixed. `tools/coverage.sh:59-65`:

```
if [ -z "$pct" ]; then
    # A gated CGI with NO measurement is a gate FAILURE, not a skip -
    # a silent skip is exactly how lazysite-auth.pl went unmeasured
    # for weeks (2026-07-10 review, D3).
    printf "  %-34s NOT MEASURED - gate failure\n" "$f" >&2
    fail=1
    continue
fi
```

The gate is now fail-closed against the project's own documented regression mode
(a test rebuilding `%ENV` without `env_passthrough()` dropping instrumentation
from a child). This is the exact one-line fix recommendation 1 of the prior
review asked for; it has landed.

## F3.5 - Floors ratcheted to the Commercial regime (PASS)

`dist/config/coverage-floor` now declares `floor=75` and `branch_floor=62` - the
statement floor **is** the Commercial-regime 75% by enforcement, not merely in
fact (prior review recommendation 3). Three per-file branch overrides at 60 are
retained and each is documented as guarding run-to-run instrumented-subprocess
variance, not weaker tests: `lazysite-manager-api.pl` (62.8, band 56.6-80.7),
`lazysite-auth.pl` (64.8) and `lazysite-mcp.pl` (62.8) - each within ~0.5-2.8
points of the 62 floor, thinner than the documented merge variance. The ratchet
note "never lower the others" is present. The residual subprocess-stability work
that would let the overrides be removed is tracked in
`docs/feature-requests/BACKLOG.md` (see F3.8), no longer only in a config comment.

## F3.6 - New SM179/SM165 modules are pinned at the branch and edge-case level (PASS)

The material new code since 0.7.0 is three library modules plus their CGI wiring.
Each has a dedicated unit test that exercises the branches and the
security-relevant edges, not just the happy path:

- **`Lazysite::Auth::DomainAccess`** (SM165, a confinement spine) -
  `t/unit/lib/20-domain-access.t` pins every decision branch: general-editor =
  unconfined; empty allow-list on a non-default domain = operator-only; a lock
  that narrows to nothing = `DENY_ALL_SCOPE` (with an explicit assertion that the
  deny-all list is **non-empty**, since an empty list would wrongly mean
  unconfined); disjoint `intersect_scopes` = deny-all; the tighter-scope-wins
  rule in both argument orders; and end-to-end from `read_domains` parsing
  (hosts with dots, list-valued keys) into the resolver. For a module whose bug
  would be a silent confinement escape, this is the right depth.
- **`Lazysite::Lang`** (SM179) - `t/unit/lib/40-lang.t` covers `sole_group`
  ambiguity (group declared only on alias hosts; two groups => empty), the
  "a lone host is not a set" guard, and `lang_status` file states
  (current / stale / missing) via both the mtime path **and** the
  `translated_from:` hash path, including the case where the hash overrides an
  mtime that would say otherwise (both directions).
- **`Lazysite::I18n`** (SM179 P8) - `t/unit/lib/41-i18n.t` pins the fail-closed
  contract the module's own header calls a "HARD SAFETY LINE": no lang / unknown
  key / unparseable JSON / empty translation / traversal lang code all yield the
  English string, and `%s` interpolation is HTML-escaped (a reflected-markup
  check on `notfound.body`). This is the correct emphasis - the failure that
  matters is a mis-set language blanking a page or hiding why sign-in failed.

Beyond the unit tier, the feature is covered at integration and API level:
`t/integration/{19-lang-awareness,21-language-set,22-sitemap-hreflang,24-chrome-i18n,16-domain-aliases,18-domains-served}.t`,
`t/unit/manager/{31-domain-confinement,32-domains-engine,33-domains-api,34-domain-check,35-lang-status-api,36-lang-whoami}.t`,
`t/unit/mcp/06-lang-note.t`, `t/tools/32-domain-rewrites.t`. The processor keeps
a **local copy** of the domain-access logic to hold the render path module-free,
and that divergence is recorded (ADR 0001, `lazysite-processor.pl:641`) and
exercised through `t/unit/processor/28-domains-nav.t` and
`t/integration/18-domains-served.t` - a divergent-implementation risk that is
both ADR-recorded and independently tested, not silently forked.

## F3.7 - The conf-mtime cache-invalidation fix is pinned (PASS)

The cache-correctness change (a cached render now depends on `lazysite.conf`
mtime, not only the `.md`) is directly regression-tested by
`t/integration/25-conf-cache-invalidation.t`. The test reproduces the reported
field bug precisely: render under `lang: en` populating the cache, a cache hit
confirming en, then a **conf-only** edit to `lang: de` (with the `.md` forced
older than the cache and the conf forced newer) and an assertion that the next
render is NOT served stale but re-renders under `lang: de`, reflected in both the
`Content-Language` header and `<html lang="de">`. Both correctness branches in
`try_serve_cache` (`lazysite-processor.pl:1072-1089`) - the mtime path and the
TTL path - gate on `$conf_mtime`, and the test drives the mtime path.

## F3.8 - Prior-review residuals are now tracked in the backlog (FIXED, was WARN F3.10)

The prior review flagged two items living only inside review documents or config
comments. Both are now in `docs/feature-requests/BACKLOG.md`
(lines 171-173): the subprocess-coverage-stability work (which would retire the
branch overrides) and a test pinning the 0.6.6 `install.pl` ownership-scoping fix
appear as named items (d) and (e) in the eight-dimension follow-up entry. The
`install.pl` regression pin (prior recommendation 4) is tracked but not yet
written; `install.pl` remains the least-protected production script (outside the
gate, twice field-hit in the 0.6.x line), so this stays a live low-severity gap
rather than a closed one.

## F3.9 - Documentation currency (WARN, minor, Dimension 7 carry)

`docs/architecture/test-coverage.md` still records "2048 tests across 141 files
(2026-07-02)" and the v0.6.10-era per-module table. Against today's 4179 / 232
and the current per-CGI figures in F3.3 this is one full cycle stale. The gate
and floor file are current; the human-readable coverage evidence is not. This is
a documentation-dimension freshness item, not a Dimension 3 gate failure - the
mechanical gate is the line of defence and it is correct - but a Commercial-regime
stable cut should carry current evidence.

# Prior findings - disposition

```datatable
columns: Prior finding (v0.6.10) | Disposition at v0.7.28
widths: 7cm | X
bold: 1
tone: light
---
F3.6 mcp/oauth measured but ungated; oauth would fail branch floor | FIXED - both gated (coverage.sh:43-45); oauth branch coverage raised to 94.6 via t/unit/oauth/03-branches.t
F3.7 "not measured" is a silent skip (fail-open) | FIXED - sets fail=1 (coverage.sh:59-65); gate is fail-closed
F3.4/rec3 enforced floors below the Commercial 75% | FIXED - floor=75, branch_floor=62; three documented per-file branch overrides at 60 retained for variance
F3.8/rec4 install.pl ownership fix unpinned; install.pl outside gate | OPEN (tracked) - backlog item (e); install.pl still ungated (documented), still unpinned
F3.10 residuals only in config comments / review docs | FIXED - subprocess-stability + install.pl pin now backlog items (d)(e)
F3.10 test-coverage.md stale | OPEN - still 2048/141 vs today's 4179/232 (F3.9)
```

# Recommendations

1. Refresh `docs/architecture/test-coverage.md` to the candidate: suite totals
   (4179 / 232), the current per-CGI table from F3.3, and note the mcp/oauth gate
   additions and the three branch overrides. Where: `docs/architecture/test-coverage.md`.
   Effort: S. Satisfies: coverage-evidence currency for the stable cut (F3.9).
2. Retain the 0.7.28 release suite log (as prior cuts did under
   `/srv/tmp/sm-test/rel*-suite.log`) so the "4179 pass" claim has a retained
   artefact rather than a review-brief assertion. Where: release procedure /
   `docs/development.md`. Effort: S. Satisfies: reproducible green-suite evidence
   for the DoC (F3.2).
3. Write the `install.pl` ownership-scoping regression test (backlog item e): a
   root-skippable test asserting the repair touches only root-owned paths and
   never re-owns CGI runtime files - `t/tools/03-install-pl.t` has the harness.
   Where: `t/tools/`. Effort: M. Satisfies: the twice-field-hit, ungated script
   gets a pin (F3.8).
4. When the subprocess-coverage-stability work (backlog item d) lands, remove the
   three per-file branch overrides and confirm auth/mcp/manager-api clear the 62
   branch floor on their own. Where: `dist/config/coverage-floor`. Effort: M.
   Satisfies: the enforced branch floor becomes uniform (F3.5).
