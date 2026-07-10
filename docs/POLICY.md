# lazysite - Policy and compliance posture

The project's regulatory posture and the artefacts the chosen regime requires.
Vulnerability handling and the security model are in
[SECURITY.md](../SECURITY.md) and `docs/architecture/security.md`.

## Regime: Commercial

lazysite is offered commercially (operator-deployed, and exposed to external AI
publishing partners). This selects the **Commercial** posture of the
eight-dimension framework: the EU **Cyber Resilience Act (Reg. (EU) 2024/2847)**
Article 13 manufacturer duties apply, alongside OpenChain process policies and
the documentation/quality floors below. (The heavier *Commercial-regulated*
overlay - ISO 27001 Statement of Applicability + sector rules - is **not**
selected. A STRIDE/ASVS threat model is a plain Commercial requirement for a
user-facing service, not part of that overlay: see `docs/SECURITY.md`.)

## Licensing and supply chain

- **Licence:** MIT (see `LICENSE`, `COPYRIGHT`).
- **Dependencies:** core Perl plus optional Template Toolkit, Archive::Zip,
  DB_File - enumerated with SPDX licences in `dist/config/sbom-deps.json`. A
  **strict SBOM gate** (`tools/manifest-to-sbom.pl --strict`) fails any release
  whose code imports a module not declared there, so the SBOM cannot drift from
  the code.
- **SBOM:** generated per release (CycloneDX) and shipped in the tarball.

## CRA Article 13 obligations (status)

| Obligation | Status |
|---|---|
| SBOM, kept current | **in place** (strict gate) |
| Coordinated vulnerability disclosure | **in place** (SECURITY.md) |
| Quality + documentation floors (8-dimension) | **partial** - the mechanical gates run per release (coverage floors, perf gate, SBOM, lint); the 2026-07-01 eight-dimension review found WARN on several dimensions and its follow-up actions are in progress (see `docs/review/2026-07-01-eight-dimension/`) |
| Declaration of Conformity | **drafted** - `docs/DECLARATION-OF-CONFORMITY.md`; to be finalised and signed at the 0.7.0 stable cut |
| Annex VII technical file | **pending** |
| Support-period commitment | **declared** - five years from the first stable release (0.7.0); see "Support period" below |
| Signed releases (Sigstore/cosign) | **pending** |
| CE marking | **due 11 Dec 2027** - obligation noted; not yet applied |
| OpenChain 5230 (component policy) + 18974 (security assurance) written policies | **pending** |

The "pending" rows are tracked work (review item 7 / WP-5). This document is the
posture of record; it does **not** claim conformity that is not yet in place.

## Support period

lazysite commits to a support period of **five years from the first stable
release (0.7.0)**, satisfying the CRA Art. 13 requirement at the framework's
default. Security fixes are delivered on the **stable** release channel for
the duration of that period (development continues on the edge channel; see
ADR 0005 for the channel mechanism). This commitment is recorded here, in
`SECURITY.md`, and in the Declaration of Conformity
(`docs/DECLARATION-OF-CONFORMITY.md`); the period's start date is fixed when
the 0.7.0 stable release is cut.

## Operational resilience

The project's declared reliability posture - SLOs, error budget, RTO/RPO
targets, the mapping of each target to its failure-mode evidence, and the
restore-rehearsal record - is in [RELIABILITY.md](RELIABILITY.md). The
targets there are the project's reference declaration for a single-host
deployment; each operator may override them for their own deployment (the
per-implementation ownership model recorded in
`docs/review/2026-07-01-eight-dimension/90-prelaunch-operational-holds.md`).

## Data protection

lazysite stores account credentials (hashed), per-account settings (incl. TOTP
seeds - see the security model for the at-rest note), and form submissions.
Operators are the data controllers for their sites; lazysite is the software.
