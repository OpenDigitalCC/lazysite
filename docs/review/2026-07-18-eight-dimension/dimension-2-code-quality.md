# Dimension 2 - Code quality - lazysite eight-dimension review

---
title: "Dimension 2 - Code quality - lazysite eight-dimension review"
subtitle: "v0.7.28 (6780878), 2026-07-18, Commercial regime, 0.8.0-stable candidate"
brand: plain
---

## Verdict

PASS - the project gate runs at the framework's stated severity 3 with zero
violations across the full production surface, including all the new SM179 /
SM165 / SM175 modules and the grown `tools/` surface; the two open items the
prior review carried are both now mechanically closed - the shellcheck gap is a
committed gate (`t/lint/07-shellcheck.t`, run at `-S error`) and the secrets
gate's vacuous check is fixed and self-tested; the lint suite has grown from six
gates to twelve, each wired into the unskippable release path; and the new code
is idiomatic, tidy, and lint-clean. The residual findings are small and
S-effort: three prior documentation counts in `code-quality.md` are still stale,
one orphaned sub remains, the complexity exclusion is still recorded as a profile
comment rather than the deliberate-keep ADR the prior review suggested, and one
new plugin carries a two-line perltidy alignment nit. None masks a shipped
violation, so the Commercial regime carries no refusal condition here.

## Method

Assessed at tag `v0.7.28`, commit `6780878` (`git describe --tags` = `v0.7.28`;
clean tree). File set: the full production glob the compile and perlcritic gates
use - `*.pl`, `tools/*.pl`, `plugins/*.pl`, `lib/Lazysite/**/*.pm` - which has
grown substantially since 0.7.0 (the diffstat shows ~12,800 insertions across 51
tracked `.pl`/`.pm` files, including the new `Lang.pm`, `I18n.pm`,
`Auth/DomainAccess.pm`, `Git.pm`, six new/heavily-changed `Manager/*.pm`, and
large new `tools/` scripts). Prior review:
`docs/review/2026-07-10-eight-dimension/dimension-2-code-quality.md` (v0.6.10).
Commands run:

- `prove -l t/lint/` - all twelve gates green (323 tests): stale-paths,
  perlcritic (sev 3), secrets, compile, perlcritic-security, tidy, shellcheck,
  retired-terms, feature-request-status, users-select-configure, web-assets-sbom,
  vhost-hardening.
- `perlcritic --profile .perlcriticrc --severity 3 --quiet` over the principal
  new / changed modules in two batches (the SM179/SM165/SM175 core, then the
  `Manager/*`, `Capabilities`, `DomainRewrites`, `content-history`/`git-sync`
  plugins, `lazysite-cli.pl`, `lazysite-users.pl`) - 0 violations, exit 0.
- `perltidy --profile=.perltidyrc -st` compared line-by-line against a sample of
  changed files (`Git.pm`, `Manager/Domains.pm`, `Lang.pm`, `I18n.pm`,
  `Auth/DomainAccess.pm`, `lazysite-cli.pl` - all clean; `plugins/git-sync.pl` -
  a two-line alignment diff, see F2.6).
- `t/lint/07-shellcheck.t` read; `t/lint/03-secrets.t` read; residue re-checks
  (`_has_settings_entry` caller grep; the `~53` / `~90` / "single duplicated
  helper" phrases in `code-quality.md`).

## Prior findings - status

```datatable
columns: Prior finding | Status | Evidence
widths: 6cm | 2.4cm | X
bold: 2
tone: medium
text: 3
---
F2.1/F2.3 project gate at framework bar + tidy gate wired | STILL PASS | `perlcritic --profile .perlcriticrc --severity 3` over the grown production surface: 0 violations; `t/lint/02-perlcritic.t` and `06-tidy.t` remain in the release-path `prove -r t/`
F2.4 secrets gate's vacuous private-key check (`invalid-test`) | FIXED | `t/lint/03-secrets.t` uses `-e` per pattern and a `%plant` self-test block asserting each check CAN fire (owned by D1 F1.3/F1.4; verified here as gate-quality)
F2.5 no shellcheck gate over shipped bash | FIXED | `t/lint/07-shellcheck.t` runs `shellcheck -S error` over every tracked `*.sh` (asserts >=5 scripts found); skips cleanly if absent, and `tools/release.sh` asserts the tool separately so a release host cannot skip silently
F2.6 complexity hotspots open by decision | OPEN BY DECISION (unchanged) | The three complexity policies remain excluded as documented house convention; still recorded as a profile comment / architecture-doc "refactor candidate", not the deliberate-keep ADR the prior review suggested
F2.7 dead code + stale doc counts | PARTLY OPEN (low) | `_has_settings_entry` (`tools/lazysite-users.pl:2509`) still orphaned; `code-quality.md` still carries "~53 hits" (raw 99), "~90" (raw 100) and "single duplicated helper" (two copies exist)
```

## Findings

### F2.1 - Project gate green at the framework bar over a much larger surface (PASS)

`perlcritic --profile .perlcriticrc --severity 3` returns zero violations across
the production glob, which since 0.7.0 has absorbed the entire new multilingual
layer (`Lang.pm`, `I18n.pm`), the domain-access model (`Auth/DomainAccess.pm`),
the content-history core (`Git.pm`, 445 lines), six new/heavily-changed
`Manager/*` modules, two substantial new plugins (`content-history.pl`,
`git-sync.pl`), and large new `tools/` scripts (`lazysite-cli.pl` +801 lines,
`lazysite-users.pl` +936, plus the vhost/hestia/nginx/pool provisioning tools).
The profile bar and the framework bar are the same number (severity 3), and the
gate runs inside the release path's `prove -r t/`, so a severity-3 violation
refuses the build - the by-design prevention the framework names. This is the
strongest evidence for the verdict: a large body of AI-assisted new code landed
lint-clean at the framework's bar.

### F2.2 - New code is idiomatic and tidy (PASS)

The new modules follow the project's established shape: `strict`/`warnings`,
`Exporter` with an explicit `@EXPORT_OK`, small single-purpose subs, list-form
system calls, and header comments that cite the SM number, the design decision,
and (in `Git.pm` and `I18n.pm`) the field incident or the HARD SAFETY / HARD
SCOPE line the module must hold to. `perltidy --profile=.perltidyrc` is clean on
the sampled new files (`Git.pm`, `Manager/Domains.pm`, `Lang.pm`, `I18n.pm`,
`Auth/DomainAccess.pm`, `lazysite-cli.pl`) - the calibrated house style holds.
Comment discipline remains a genuine strength: implementation comments state
*why*, not *what*, and the tests' header comments cite the review finding they
pin (e.g. `t/unit/auth/11-non-ascii-settings.t` names the 2026-07-10 D1 finding).

### F2.3 - The lint suite doubled and each gate is wired (PASS)

Six gates at the prior review; twelve now. The two the prior review recommended
adding are both present: `07-shellcheck.t` (F2.5, below) and - beyond the
dimension - `08-retired-terms.t`, which makes the recurring
documentation-currency defect the prior D1/D7 reviews chased unshippable. The
suite runs inside `tools/release.sh`'s staging-clone `prove -r t/`, so none of
the twelve is flag-skippable at release, and the release script now asserts the
external tools exist (the "make tool-absent skips visible at release"
recommendation from the prior review, applied to shellcheck at least - see the
gate's own header comment referencing `tools/release.sh`).

### F2.4 - shellcheck gate closes the last declared-tooling gap (PASS)

`t/lint/07-shellcheck.t` runs `shellcheck -S error` over every tracked `*.sh`,
asserts at least five scripts are found (so an empty glob cannot pass vacuously -
the exact self-test discipline the prior review asked lint gates to adopt), skips
cleanly where shellcheck is absent, and is backed by a `release.sh` tool-presence
assertion so a minimal release host refuses loudly rather than skipping silently.
The framework's per-language line for this dimension (`shellcheck -S error` on
every shipped script) is now a real by-design refusal, not a hand-run check.

### F2.5 - Module boundaries hold; the new ADR-0001 copy is marked (PASS / observation)

The ADR-0001 divergence discipline was spot-checked at the new sites: the SM138
processor copy (`_site_grants_manager`) remains marked with the ADR reference, and
the new modules respect the boundary they declare (`Lazysite::Lang` documents and
holds its READ-ONLY scope; `Lazysite::Auth::DomainAccess` centralises the
allow/lock logic in one `_effective_hosts` helper consumed by both public
resolvers, avoiding the divergent-implementation shape). The one boundary caveat
is the documentation of the divergence set, not the code: ADR 0001 and
`code-quality.md:16` still describe "one recorded copy" / "single duplicated
helper" against two marked copies - owned by Dimension 1 (F1.9) as the
divergence-record drift it is, noted here because a lint signal will never catch a
record that under-counts the copies it is supposed to enumerate.

### F2.6 - Complexity still open by decision; one tidy nit; stale doc counts (WARN, low)

Three low residues, none masking a shipped violation:

- **Complexity (F2.6 prior, unchanged).** The three complexity policies remain
  excluded as documented house convention (the if/elsif dispatchers), still
  recorded as a profile comment and an architecture-doc "refactor candidate"
  rather than the deliberate-keep ADR the prior review recommended. With the
  window's new dispatch-heavy `Manager/*` and `tools/*` code the over-threshold
  count will have grown again; the position is honest but a profile comment is a
  weaker record than the framework's deliberate-keep ADR shape for a decision a
  future refactor should not silently revisit. Effort S (ADR) or L (refactor).
- **Tidy nit.** `plugins/git-sync.pl` (new at SM085 phase 1) has a two-line
  perltidy alignment difference under `.perltidyrc` (a hash `=>` alignment on
  lines 101-102). The changed-code tidy gate flags only lines a change touched
  since the last release tag, so this may sit below the gate's delta window; per
  the house rule that new files should be tidied wholesale before commit, it is
  worth a one-shot `perltidy` pass. Effort S.
- **Stale doc counts (F2.7 prior, unchanged).** `docs/architecture/code-quality.md`
  still reads "~53 hits" for `ProhibitExplicitReturnUndef` (line 77; raw count is
  99) and "~90" for `RequireEncodingWithUTF8Layer` (line 74; raw 100), and "its
  single duplicated helper" (line 16; two copies exist). The rationales still
  hold; the numbers and the singular no longer do. `_has_settings_entry`
  (`tools/lazysite-users.pl:2509`) remains the one orphaned sub. Effort S.

## Recommendations

1. Give `plugins/git-sync.pl` a one-shot `perltidy --profile=.perltidyrc`
   in-place pass (and re-check the other new plugins/tools the same way), so new
   files are wholesale-tidy per the house rule rather than relying on the
   changed-code gate's delta window (F2.6). Effort S.
2. Refresh the residual staleness in `docs/architecture/code-quality.md` (99 not
   ~53, 100 not ~90, two marked processor copies not one) and delete the orphaned
   `_has_settings_entry` (F2.6; shares the doc side with D1 F1.9). Effort S.
3. Record the dispatcher complexity exclusion as a deliberate-keep ADR (context:
   the self-contained CGI dispatch style; consequence: the excluded policies and
   the over-threshold residue), converting F2.6 from open-by-convention to
   recorded-by-decision so a future refactoring agent sees the boundary. Effort S.
4. Optionally extend the tool-presence assertion in `tools/release.sh` to cover
   `perlcritic` and `perltidy` explicitly (if not already), so every code-quality
   gate refuses loudly on a minimal release host rather than skipping. Effort S.
