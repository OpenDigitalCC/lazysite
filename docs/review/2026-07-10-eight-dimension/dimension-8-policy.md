---
title: "Dimension 8 - Policy compliance - lazysite eight-dimension review"
subtitle: "v0.6.10 (5aa6f27), 2026-07-10, Commercial regime"
brand: plain
---

## Verdict

REFUSE - both factual defects the 2026-07-01 review found in the posture of record are fixed (the CRA is now correctly cited as Regulation (EU) 2024/2847; the support-period self-contradiction with `SECURITY.md` is reconciled), the claimed-met CRA obligations remain genuinely evidenced, and the Art. 13 status table is now honest about the quality floors - but the two gate items the framework names as unconditional refusal conditions for a Commercial-regime release, the Declaration of Conformity and the support-period statement, are still absent and unwaived, and seventeen further releases (v0.5.36-v0.6.10) have been publicly committed (tagged and pushed) since that was found. A new defect compounds it: the shipped CycloneDX SBOM misdeclares the licence of lazysite's own code as Artistic-1.0-Perl on 211 of 213 components, including the product component itself, where `LICENSE`, `COPYRIGHT` and `docs/POLICY.md` all say MIT. Strictly applied, the dimension refuses; the path back to WARN is short (one operator decision plus two small artefacts, or a dated waiver).

## Method

Assessed at tag `v0.6.10`, commit `5aa6f27` (clean tree). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md` Dimension 8 detail and Commercial-regime requirements (all eight dimensions, coverage >= 75%, OpenChain 5230 + 18974, strict SBOM, signed releases, support period declared with the 5-year default, Annex VII technical file); `/srv/projects/toolchain-development/POLICY.md` CRA rows (:71, :145, :186-189, :353-356); `/srv/projects/toolchain-development/IMPLEMENTATION.md` lazysite rows (:141, :793, :840, :871, :1363, :1450). Work performed:

- `docs/POLICY.md` read in full; both 07-01 factual defects re-checked; every status row re-verified.
- Evidence check of each claimed-met obligation: `dist/lazysite-0.6.10.tar.gz` listed and its `sbom.json` extracted (to `/srv/tmp/sm-test/review-d78/`) and inspected component-by-component; `tools/release.sh` read end-to-end for the gate chain; root `SECURITY.md` and `docs/OPERATOR.md` read.
- Licence cross-check: `LICENSE` / `COPYRIGHT` / POLICY.md declarations against the SBOM's per-component and metadata licence ids, traced to `tools/manifest-to-sbom.pl` (:173, :242) and `dist/config/sbom-deps.json`.
- Negative sweeps: repo and `dist/` for conformity artefacts, OpenChain policies, VEX, and signature files (`.sig`/`.asc`).
- Release-evidence check: gate claims in the release commits (e.g. `31ae86b`, 0.6.9) against the machinery in `release.sh`; suite state at 0.6.10 cited from `/srv/tmp/sm-test/rel610-suite.log` (162 files, 2504 tests, Result: PASS). Heavy gates owned by other dimensions were not re-run.

## Findings

### F8.1 - Both prior factual defects in the posture of record are fixed (PASS)

- `docs/POLICY.md:11` now cites "Cyber Resilience Act (Reg. (EU) 2024/2847)" - the correct regulation number, matching framework POLICY.md:186-189. Fixed in 0.5.37 (CHANGELOG: "docs/POLICY.md corrects the CRA citation to Reg. (EU) 2024/2847"). No seven-dimension wording survives anywhere outside the archived review directories.
- The support-period self-contradiction is reconciled: root `SECURITY.md:3-10` now states that the rolling-latest posture "is the interim practice, not the committed policy", names the CRA Article 13 requirement and the expected five-year period, and points at `docs/POLICY.md` as where the commitment will be recorded. The two documents now tell one story. The commitment itself remains unmade (F8.4).
- The 07-01 "overstated" finding on the quality-floors row is also fixed: `docs/POLICY.md:34` now marks it "partial", cites the mechanical gates that run per release, and links the 2026-07-01 review and its in-progress follow-ups - the honest-declaration shape the framework wants.

### F8.2 - Claimed-met CRA Article 13 obligations: evidence re-check (PASS)

```datatable
columns: Obligation | POLICY.md claim | Evidence at v0.6.10 | Verdict
widths: 3.4cm | 2cm | X | 1.8cm
bold: 1
tone: medium
text: 3
---
SBOM, kept current | in place (strict gate) | release.sh:242-252 runs manifest-to-sbom.pl --strict against the staged tree and refuses on any undeclared module; sbom.json ships in the tarball root (CycloneDX, 213 components, per-file SHA-256, SPDX ids); .sha256 sidecars beside every tarball since 0.5.37 | evidenced - but see F8.3 on the licence field
Coordinated vulnerability disclosure | in place | SECURITY.md: private GitHub advisories channel, 48-hour acknowledgement, 7-day fix-timeline for critical, in/out of scope defined | evidenced
Security update mechanism | implied | edge/stable channels (release.sh:41-54, --final marks stable); install.pl --channel + --force with audit events; hestia update-all honours update_channel; now ALSO documented repo-side in OPERATOR.md:43-53, closing the 07-01 caveat | evidenced - though the Art. 13 table no longer carries an explicit update-mechanism row (minor)
Quality + documentation floors | partial (honest) | the gate chain runs per release in release.sh: full suite, bench.pl --check, coverage.sh --check, strict SBOM; release commits record per-release gate claims (31ae86b: suite size, perlcritic sev-3, security lint, compile, tidy, bench, strict SBOM, coverage-by-identity argument); suite green at 0.6.10 per /srv/tmp/sm-test/rel610-suite.log | evidenced and honestly stated
```

The release-commit gate claims are contemporaneous evidence of exactly the kind an Annex VII technical file needs; the practice of recording the coverage-holds-by-identity reasoning in the commit (0.6.7, 0.6.9) is notably good discipline.

### F8.3 - New: the shipped SBOM misdeclares lazysite's own licence (WARN)

`tools/manifest-to-sbom.pl` hardcodes `Artistic-1.0-Perl` both for every own-source component (:173) and for the top-level `lazysite` application component in `metadata.component` (:242). The result in the shipped `sbom.json` at 0.6.10: 211 of 213 components carry `Artistic-1.0-Perl`, including `lazysite-auth.pl`, every `lib/Lazysite/*.pm` and the product itself - while `LICENSE`, `COPYRIGHT` and `docs/POLICY.md:20` declare MIT. (The dependency entries drawn from `dist/config/sbom-deps.json` are correct - Perl core modules genuinely are Artistic-1.0-Perl; the defect is the same default applied to lazysite's own MIT files.)

This matters at Dimension 8 because the SBOM is a compliance artefact of record: the wrong own-licence would propagate verbatim into the technical file, any OpenChain 5230 evidence, and downstream consumers' licence-obligation analysis. It also silently pre-empts the open relicensing question (IMPLEMENTATION.md:871 proposes AGPL-3.0-only, unconfirmed) with a third licence that was never chosen. The fix is two lines plus regeneration at the next release. `COPYRIGHT` itself is a good third-party-notices statement (self-contained code, deps enumerated with SPDX ids); the SBOM is the one artefact contradicting it.

### F8.4 - The unique Dimension 8 gate items at v0.6.10 (REFUSE conditions)

Declaration of Conformity
: absent - no conformity artefact anywhere in the repo or `dist/` (swept); POLICY.md:35 marks it pending. The framework: "a missing Declaration of Conformity refuses a commercial-regime release". Seventeen releases have been tagged and pushed since this was found; the framework's alternative - an auditable, named, dated waiver - has not been recorded either. Condition met.

Support-period commitment
: absent - POLICY.md:45-49 still says "to be set by the operator", and SECURITY.md correctly labels the current posture interim. "A missing support-period statement refuses too." This is one operator decision (the framework default is five years, POLICY.md:71/:356) plus two edits. Condition met.

Signed releases
: pending as declared. No `.sig`/`.asc` anywhere in `dist/`; `release.sh` has no signing step. The `.sha256` sidecars provide integrity, not authenticity.

CE marking readiness
: due 11 December 2027 (correctly noted, POLICY.md:39, matching IMPLEMENTATION.md:141); ~17 months of runway. No readiness checklist yet (07-01 rec 8 open). The dependency chain DoC -> technical file -> support period -> signing is unchanged and unstarted at the artefact level.

OpenChain 5230 + 18974 written policies
: absent (swept); the practices they would transcribe (strict SBOM gate, CVD) demonstrably run.

VEX
: absent; IMPLEMENTATION.md:1363 expects `releases.opendigital.cc/lazysite/<version>/vex.json` for lazysite. Not claimed in POLICY.md, so not a false claim - still a gap in the CRA vulnerability-handling artefact set.

Annex VII technical file
: absent as an assembled artefact; its inputs now largely exist (FEATURES.md, docs/SECURITY.md threat model, architecture docs, sbom.json, per-release gate evidence in the release commits) - the remaining work is genuinely the curated index the 07-01 review described.

### F8.5 - Regime fit and posture quality (PASS)

The Commercial declaration remains correct and has improved in precision: POLICY.md:13-16 now explicitly notes that the STRIDE/ASVS threat model is a plain Commercial requirement rather than part of the declined commercial-regulated overlay - closing a subtle 07-01-era misread and matching the framework. The product facts have not changed regime: operator-deployed CGI site builder, commercial client deliveries (IMPLEMENTATION.md:141), credentials/TOTP/form data, external AI publishing partners; not sector-regulated, not an AI system. Two standing notes carried forward: the AGPL relicensing proposal remains open (POLICY.md correctly reflects current MIT reality - but see F8.3); hosted-operation postures for client sites remain correctly out of this product-level document.

### F8.6 - Update channels as a policy artefact; the 0.7.0 stable cut is the deadline that matters (WARN)

The edge/stable machinery is complete and now documented at both levels (release.sh; OPERATOR.md:43-53; install.pl `--channel`/`--force` with audit events). Every 0.6.x release is channel edge; no `--final` stable has been cut in the window, and the backlog (CHANGELOG 0.6.10) sequences SM141 "after the review and 0.7.0 stable". That stable cut is the framework's public commercial commitment in its sharpest form - the release customers are pinned to. Shipping it without the support-period statement and a DoC (or a recorded waiver) would convert this dimension's refusal from a review verdict into a live compliance exposure with a customer on the other end.

## Verdict rationale

This round applies the refusal conditions strictly, as charged. The framework names exactly two unconditional Dimension 8 refusal conditions for a Commercial-regime release and both are met at v0.6.10, unresolved and unwaived (F8.4); the 07-01 round graded the same absences WARN, but the strict reading plus their persistence across seventeen further public releases makes REFUSE the honest verdict. Everything else moved the right way: the posture of record is accurate and honest, the evidenced obligations held up to re-inspection, and the one new defect (F8.3) is small and mechanical. Recommendations 1-2 (or the waiver of recommendation 4) return the dimension to WARN; they must land before the 0.7.0 stable cut regardless.

## Recommendations

1. Set the support period - one operator decision, framework default five years - and record it in `docs/POLICY.md` (replacing the "to be set" text), `SECURITY.md`, and the DoC template. Effort: S. Gate: clears one refusal condition.
2. Draft the Declaration of Conformity template (product id, Reg. (EU) 2024/2847, harmonised standards, support period from rec. 1, signatory) and populate it for the 0.7.0 stable release; legal review before any external use. Where: `docs/conformity/`. Effort: M. Gate: clears the other refusal condition.
3. Fix `tools/manifest-to-sbom.pl` (:173, :242) to declare MIT for lazysite's own components and the metadata component; regenerated SBOM ships with the next release. Effort: S. Gate: SBOM licence accuracy; blocks a wrong technical file.
4. If the operator elects to defer recs 1-2 past the next edge release, record the framework's waiver instead - named, dated, with the 0.7.0 target - in `docs/POLICY.md`. Effort: S. Gate: converts an unmanaged refusal into an auditable one; the framework explicitly provides this path.
5. Add a signing step (Sigstore/cosign) to `tools/release.sh`, publish `.sig` beside each tarball, and add a verification note to `UPGRADE.md`. Effort: M. Gate: signed releases (Commercial regime requirement).
6. Write the OpenChain 5230 and 18974 policies from the framework templates - transcription of practices that already run. Where: `docs/`. Effort: S. Gate: OpenChain written policies.
7. Add per-release VEX generation (`vex.json` beside `sbom.json`) per IMPLEMENTATION.md:1363. Effort: M. Gate: CRA vulnerability-handling artefact set.
8. Add the CE-marking readiness checklist section to `docs/POLICY.md` tracking recs 1, 2 and 5 with owners and dates against 11 December 2027. Effort: S. Gate: CE readiness (07-01 rec 8, still open).
9. Restore an explicit "security update mechanism" row to the Art. 13 status table, citing the channel machinery and OPERATOR.md. Effort: S. Gate: posture completeness.
10. Assemble the Annex VII technical-file index over the now-existing artefacts (threat model, FEATURES, architecture set, SBOM, release-commit gate evidence). Where: `docs/technical-file/`. Effort: L. Gate: Annex VII.
