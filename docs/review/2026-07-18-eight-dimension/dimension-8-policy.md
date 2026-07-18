# Dimension 8 - Policy compliance - lazysite eight-dimension review

---
title: "Dimension 8 - Policy compliance - lazysite eight-dimension review"
subtitle: "v0.7.28 (6780878), 2026-07-18, Commercial regime, 0.8.0-stable candidate"
brand: plain
---

## Verdict

WARN - all three 2026-07-10 refusal-class defects are cleared. The two
unconditional Dimension 8 gate items are now present: the Declaration of
Conformity exists (`docs/DECLARATION-OF-CONFORMITY.md`), complete in every
substantive section (product id, sole-responsibility, Annex I requirement->evidence
mapping, standards, notified-body/self-assessment, signatory block) and unsigned
by design; and the support period is declared - five years from the first stable
release (0.7.0), recorded coherently across `docs/POLICY.md:37/:45-54`,
`SECURITY.md` and the DoC. The SBOM licence defect is fixed: at this tree
`tools/manifest-to-sbom.pl` declares MIT for lazysite's own components and for
the top-level metadata component (:173, :266), and the freshly-built SBOM carries
MIT on every own component (incl. the `lazysite` metadata component, all
`lazysite-*.pl` and every `lib/Lazysite/*.pm`; 0 own components mislabelled),
with `Artistic-1.0-Perl` now confined to the genuine Perl-core dependencies. The Commercial required-artefact set is otherwise present
(threat model, LICENSE=MIT, strict SBOM, pentest ADR 0007 + waiver, compat-freeze
ADR 0008). The dimension holds at WARN rather than PASS on three counts, none a
refusal condition: the DoC is templated for the *0.7.0* cut (which already
shipped 2026-07-10) and needs its version finalised to 0.8.0 plus the physical
signature at this stable cut; signed releases, OpenChain written policies and the
assembled Annex VII technical file remain pending as declared. The DoC's unsigned
state is the expected operator action at the stable cut, not a refusal - the
document is otherwise complete and does not overclaim.

## Method

Assessed at tag `v0.7.28`, commit `6780878` (clean tree apart from this review
directory). Framework: `/srv/projects/toolchain-development/TOOLCHAIN.md`
Dimension 8 detail and Commercial-regime requirements (all eight dimensions,
coverage floors, strict SBOM, signed releases, support period declared with the
five-year default, DoC, Annex VII technical file); the CRA Article 13 duties.
Work performed:

- `docs/POLICY.md` and `docs/DECLARATION-OF-CONFORMITY.md` read in full; each
  2026-07-10 refusal-class defect re-checked on disk.
- SBOM licence re-check: built the manifest and SBOM at this tree -
  `perl tools/build-manifest.pl --staged . --out /tmp/rm.json --version 0.8.0 --channel stable`
  (209 files) then
  `perl tools/manifest-to-sbom.pl --strict --manifest /tmp/rm.json --deps dist/config/sbom-deps.json --out /tmp/sbom.json --version 0.8.0 --staged .`
  (249 components, strict gate clean, exit 0). Parsed per-component and
  metadata-component licence ids; traced the fix to `tools/manifest-to-sbom.pl:173`
  and `:266`.
- Required-artefact table walk against `docs/POLICY.md`'s CRA Art. 13 status
  table; each unconditional item verified present on disk (DoC, support period,
  threat model, LICENSE, SBOM).
- Pentest posture: `docs/adr/0007-pentest-deferral.md` (declaration + dated
  waiver with expiry) read; compat-freeze consistency: `docs/adr/0008-stable-compatibility-freeze.md`
  read against the five-year stable commitment.
- Suite state: full run `prove -lr t/` at this tree, 232 files / 4179 tests,
  Result: PASS; the four named gates
  (`t/lint/08-retired-terms.t`, `t/lint/09-feature-request-status.t`,
  `t/tools/26-capability-docs.t`, `t/lint/11-web-assets-sbom.t`) run
  individually, all PASS.

## Findings

### F8.1 - Prior refusal condition 1: Declaration of Conformity now present and complete (cleared)

`docs/DECLARATION-OF-CONFORMITY.md` exists (absent at 0.6.10). It is a complete
EU DoC under Reg. (EU) 2024/2847: product identification (:17-29), manufacturer
(Open Digital CC, :31-33), sole-responsibility statement (:35-38), object of the
declaration (:40-47), a requirement-area -> evidence-of-record mapping across all
CRA Annex I areas incl. SBOM and support period (:49-69), the standards/specifications
applied with the no-harmonised-standards note (:71-83), the notified-body /
internal-control self-assessment statement for a default-category product
(:85-89), and the signatory block (:91-105, Stuart J Mackintosh, Responsible
person). The framework's refusal condition - "a missing Declaration of Conformity
refuses a commercial-regime release" - is no longer met. The document is
correctly scoped as a draft that "claims no conformity not yet in place" (:13-15)
until signed, so it does not overclaim.

The single open item is the physical signature and the date/place of issue
(:103-104, "To be completed at the 0.7.0 stable cut"; :104 "(unsigned draft)").
Per the framework and the standing memory note, the signature is an **expected
operator action at the stable cut, not a refusal** while the document is otherwise
complete - which it is. See F8.6 for the version-stamp finalisation that must
accompany the signature.

### F8.2 - Prior refusal condition 2: support period declared (cleared)

`docs/POLICY.md:45-54` states a firm commitment: "five years from the first
stable release (0.7.0)", security fixes on the stable channel for the duration,
delivery via the edge/stable mechanism (ADR 0005), with the start date fixed at
the 0.7.0 cut. The commitment is recorded in the three places the last round
asked for and they tell one story: `docs/POLICY.md:37` (Art. 13 table row,
"**declared**"), the "Support period" section (:45-54), and the DoC's requirement
mapping (DECLARATION-OF-CONFORMITY.md:67). The framework's "a missing
support-period statement refuses too" condition is no longer met. The five-year
period is the framework default; 0.7.0 (first stable, 2026-07-10) is the correct
anchor, so this candidate (0.8.0) sits inside the already-running window.

### F8.3 - Prior defect 3: SBOM own-licence corrected to MIT (cleared)

The 0.6.10 defect - 211/213 components incl. the product itself mislabelled
`Artistic-1.0-Perl` where LICENSE/COPYRIGHT/POLICY say MIT - is fixed at source
and verified in a fresh build:

```datatable
columns: Check | 0.6.10 (prior) | v0.7.28 (this tree)
widths: 5cm | 3.5cm | X
bold: 1
tone: medium
text: 3
---
metadata.component `lazysite` licence | Artistic-1.0-Perl | **MIT** (manifest-to-sbom.pl:266)
own-source components (lazysite-*.pl, lib/Lazysite/*.pm) | Artistic-1.0-Perl | **MIT**, all (manifest-to-sbom.pl:173)
Artistic-1.0-Perl usage | 211 own+dep components | 31, all genuine Perl-core deps only
Own components mislabelled Artistic | 211 | **0**
Strict-gate build (--strict) | n/a | clean, exit 0 (249 components)
```

The two hardcodes the last round named (:173 own components, :242->now :266
metadata component) both now emit `{ license => { id => 'MIT' } }`. LICENSE
(MIT License, Copyright (c) 2026 Open Digital CC) and COPYRIGHT ("Licensed under
the MIT License") are consistent with the SBOM, so the compliance artefact of
record no longer contradicts the licence file, and a wrong own-licence can no
longer propagate into a technical file or downstream obligation analysis. The
residual non-MIT ids in the SBOM (`Artistic-1.0-Perl` x31, `OML` on FCGI,
`Artistic-2.0`, `LGPL-2.1-only`, `BSD-3-Clause`, and three tool-provenance
components with no id: perl/git/Apache) are all correct third-party/tool entries,
not lazysite's own code.

### F8.4 - Commercial required-artefact set: unconditional items present (PASS)

```datatable
columns: Unconditional Commercial artefact | State at v0.7.28 | Evidence
widths: 4.4cm | 2cm | X
bold: 1
tone: medium
text: 3
---
Declaration of Conformity | present (unsigned draft) | DECLARATION-OF-CONFORMITY.md, complete (F8.1)
Support period declared | present | POLICY.md:45-54 (F8.2)
Threat model | present | docs/SECURITY.md, STRIDE/ASVS (9 STRIDE/ASVS refs); architecture/security.md mechanism narrative
Licence file | present | LICENSE (MIT), COPYRIGHT (MIT third-party-notices)
SBOM, strict + current | present | manifest-to-sbom.pl --strict clean; CycloneDX, per-file SHA-256, SPDX ids; MIT own-licence (F8.3); shipped in tarball per POLICY.md:26
```

Every artefact the framework names as unconditional for a Commercial-regime
release is present on disk. The Art. 13 status table (POLICY.md:30-40) is honest:
SBOM and CVD "in place"; DoC "drafted"; support period "declared"; quality/doc
floors "partial" with the review cross-reference; and Annex VII technical file,
signed releases, CE marking and OpenChain written policies openly "pending". No
row overclaims.

### F8.5 - Pentest posture and compatibility freeze (PASS)

- **Pentest** (framework Dimension 6/8 gate). ADR 0007 (Accepted, 2026-07-10)
  declares the `pentest:` gate and records a **named, dated deferral waiver with
  an expiry** (0007:52-55: first third-party engagement must complete before
  general-availability marketing) - exactly the auditable-waiver path the
  framework provides in lieu of a completed engagement. This is the documented
  posture the last two rounds noted as missing at the artefact level.
- **Compatibility freeze**. ADR 0008 (Proposed, 2026-07-18) states what the
  five-year stable commitment actually commits to: it names the frozen public
  surface (conf keys, control-API actions, CLI, template vars/fields, the MCP
  tool surface, 0008:26-46) as additively-changeable-only within a stable major,
  and explicitly motivates itself from this cycle's accumulated edge work -
  SM165, SM175, SM179 (0008:11-14). It is consistent with the support-period
  commitment (F8.2): a five-year support line needs a defined compatibility
  contract, and 0008 supplies it. It is correctly still "Proposed" - accepting it
  is part of the stable cut, not a precondition of this review.

### F8.6 - DoC version-stamp finalisation lags the actual cut sequence (WARN)

The DoC is templated throughout for the **0.7.0** stable release
(DECLARATION-OF-CONFORMITY.md subtitle :3; version placeholder :26; tag/tarball
:27; "at the 0.7.0 stable cut" :12, :103). But 0.7.0 was already cut as the first
stable on 2026-07-10 (CHANGELOG; FEATURES.md:1060), and the candidate under
review is **0.8.0-stable** off the 0.7.28 tree. The support-period *anchor*
(five years from 0.7.0) is correct and must not change - 0.7.0 was genuinely the
first stable. What is stale is the DoC's *product-identification* stamp: at the
0.8.0 cut the version, tag (`v0.8.0`), tarball name, and the "to be finalised at
the 0.7.0 stable cut" language all need updating to 0.8.0, alongside the physical
signature and issue date/place. This is a currency lag in a compliance artefact,
not an overclaim (the draft framing at :13-15 prevents it being one) and not a
refusal condition - but it is a required finalisation step at this specific cut,
so it is flagged here rather than left to the signing moment.

### F8.7 - Remaining declared-pending items (WARN, unchanged posture)

Carried forward from 0.6.10, still openly "pending" in POLICY.md (not overclaimed,
so not refusal conditions):

- **Signed releases** - no `.sig`/`.asc` in `dist/`; `release.sh` has no signing
  step; `.sha256` sidecars give integrity, not authenticity. Commercial-regime
  requirement; still the sharpest gap for a customer-facing stable cut.
- **OpenChain 5230 + 18974 written policies** - the practices they transcribe
  (strict SBOM gate, CVD) run, but the policy documents are not written.
- **Annex VII technical file** - inputs now largely exist (DoC, threat model,
  FEATURES once F7.4 lands, architecture set, SBOM, per-release gate evidence);
  the assembled curated index does not.
- **CE marking** - due 11 Dec 2027 (POLICY.md:39); ~17 months runway; no
  readiness checklist yet.
- **VEX** - not present, not claimed; still a gap in the CRA vulnerability-handling
  artefact set.

## Verdict rationale

All three defects that made 2026-07-10 a REFUSE are cleared on disk: the two
unconditional gate items (DoC, support period) are present and honest, and the
SBOM own-licence is corrected and verified in a fresh strict build. None of the
framework's unconditional Dimension 8 refusal conditions is met at this tree, so
REFUSE is not the honest verdict. The dimension does not reach PASS because the
DoC still needs its cut-specific finalisation (version stamp to 0.8.0 + the
physical signature, F8.6/F8.1), and signed releases, OpenChain policies and the
assembled Annex VII file remain declared-pending (F8.7) - real Commercial-regime
gaps, but openly stated and not refusal conditions. WARN is the honest verdict:
the posture of record is accurate, the gate artefacts exist, and the path to a
clean stable cut is the finalisation and signing of an already-complete DoC plus
the pending-item burn-down.

## Recommendations

1. Finalise and sign the DoC at the 0.8.0 stable cut - update the version stamp,
   tag (`v0.8.0`), tarball name and the "0.7.0 stable cut" language to 0.8.0
   (keep the five-year support anchor at 0.7.0, F8.6), complete place/date of
   issue, obtain the signature, legal review before external use. Effort: S.
   Gate: converts the complete draft into the declaration of record. **Blocks
   0.8.0-stable.**
2. Add a signing step (Sigstore/cosign) to `tools/release.sh`, publish `.sig`
   beside each tarball, and add a verification note to `UPGRADE.md`. Effort: M.
   Gate: signed releases (Commercial requirement); the last unmet mechanical gate
   in the release path.
3. Accept ADR 0008 (compatibility freeze) as part of the 0.8.0 stable cut so the
   five-year commitment has a live, accepted compatibility contract behind it.
   Effort: S. Gate: stable-commitment completeness.
4. Write the OpenChain 5230 and 18974 policies from the framework templates -
   transcription of practices that already run (strict SBOM gate, CVD). Where:
   `docs/`. Effort: S. Gate: OpenChain written policies.
5. Assemble the Annex VII technical-file index over the now-existing artefacts
   (DoC, threat model, FEATURES.md once current per D7 rec 1, architecture set,
   SBOM, per-release commit gate evidence). Where: `docs/technical-file/`.
   Effort: L. Gate: Annex VII.
6. Add per-release VEX generation (`vex.json` beside `sbom.json`) and a
   CE-marking readiness checklist to `docs/POLICY.md` tracking recs 2 and 5
   against 11 Dec 2027. Effort: M. Gate: CRA vulnerability-handling set + CE
   readiness.
