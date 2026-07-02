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
| Declaration of Conformity | **pending** |
| Annex VII technical file | **pending** |
| Support-period commitment | **pending - operator decision required** |
| Signed releases (Sigstore/cosign) | **pending** |
| CE marking | **due 11 Dec 2027** - obligation noted; not yet applied |
| OpenChain 5230 (component policy) + 18974 (security assurance) written policies | **pending** |

The "pending" rows are tracked work (review item 7 / WP-5). This document is the
posture of record; it does **not** claim conformity that is not yet in place.

## Support period

lazysite commits to providing security updates for a defined period from each
release. **To be set by the operator** (a CRA Art. 13 requirement) and recorded
here and in the Declaration of Conformity.

## Data protection

lazysite stores account credentials (hashed), per-account settings (incl. TOTP
seeds - see the security model for the at-rest note), and form submissions.
Operators are the data controllers for their sites; lazysite is the software.
