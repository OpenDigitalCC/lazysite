---
title: "lazysite - Declaration of Conformity"
subtitle: "EU declaration of conformity per Regulation (EU) 2024/2847 (Cyber Resilience Act) - draft for the 0.7.0 stable release"
brand: plain
---

# Status

This is the Declaration of Conformity for the first stable release of
lazysite, prepared in draft ahead of the cut. It becomes the declaration
of record when the version and dates are finalised and the responsible
person signs at the 0.7.0 stable release; legal review is required
before any external use. Until signed, `docs/POLICY.md` remains the
posture of record and this document claims no conformity not yet in
place.

# 1. Product identification

```datatable
columns: Field | Value
widths: 5cm | X
bold: 1
tone: medium
---
Product | lazysite - static site builder with authenticated authoring (web manager, WebDAV, control API/MCP)
Version | 0.7.0 - placeholder, to be finalised at the 0.7.0 stable cut
Unique identification | git tag `v0.7.0`; release tarball `dist/lazysite-0.7.0.tar.gz` with `.sha256` sidecar; embedded `release-manifest.json` and `sbom.json` (CycloneDX)
Release channel | stable (`release.sh --final`)
```

# 2. Manufacturer

Open Digital CC.

# 3. Sole responsibility

This declaration of conformity is issued under the sole responsibility
of the manufacturer.

# 4. Object of the declaration

The object of the declaration is the software product identified in
section 1: a Perl CGI static-site builder deployed by operators onto
their own web servers, comprising the Markdown processor, the
authentication wrapper, the web manager, the WebDAV/control-API/MCP
partner surfaces, the forms and notification subsystems, and the
install/release tooling, as packaged in the identified release tarball.

# 5. Conformity with the essential requirements

The object of the declaration described above is in conformity with the
essential cybersecurity requirements of Annex I of Regulation (EU)
2024/2847. The mapping from requirement area to the evidence of record:

```datatable
columns: Requirement area (CRA Annex I) | Evidence of record
widths: 6.2cm | X
bold: 1
tone: medium
text: 2
---
Secure by design/default; risk-based development (Part I) | The STRIDE/ASVS L1 threat model in `docs/SECURITY.md`; the mechanism narrative in `docs/architecture/security.md`; the mechanical release gates (full suite, lint, secrets, strict SBOM) recorded per release
Protection from unauthorised access; data confidentiality and integrity | The capability model and controls verified in `docs/SECURITY.md` (ADRs 0001/0003; per-file ACLs; checked writes; anonymise-at-write access log)
Availability and resilience | The reliability declaration in `docs/RELIABILITY.md` (SLOs, error budget, RTO/RPO, failure-mode test mapping, restore rehearsals)
Vulnerability handling (Part II); coordinated disclosure | The CVD policy in the repo-root `SECURITY.md` (private reporting channel, acknowledgement and fix timelines); the significant-change assessment register in `docs/SECURITY.md`
SBOM | `sbom.json` shipped in the release tarball (CycloneDX, per-file SHA-256, SPDX licence ids), regenerated per release behind the strict drift gate (`tools/manifest-to-sbom.pl --strict`)
Security updates; support period | Five years from the first stable release (0.7.0), security fixes on the stable channel - declared in `docs/POLICY.md` ("Support period"); delivery via the edge/stable channel mechanism (ADR 0005)
Obligations status overview | The CRA Article 13 obligations table in `docs/POLICY.md` - the posture of record for what is in place, drafted and pending
```

# 6. Standards and specifications applied

No harmonised standards under Regulation (EU) 2024/2847 were available
at the date of this declaration; conformity is assessed against the
essential requirements directly, applying the following standards and
specifications:

- the eight-dimension development framework
  (`toolchain-development/TOOLCHAIN.md`), aligned to ISO/IEC 25010:2023;
- STRIDE threat modelling with OWASP ASVS 4.x Level 1 verification
  (`docs/SECURITY.md`);
- CycloneDX (SBOM) with SPDX licence identifiers;
- RFC 4918 (WebDAV), RFC 6238 (TOTP) for the relevant product surfaces.

# 7. Notified body

Not applicable - lazysite is a default-category product under the CRA;
conformity is assessed under the manufacturer's internal control
procedure (self-assessment).

# 8. Signature

Signed for and on behalf of Open Digital CC.

```datatable
columns: Field | Value
widths: 5cm | X
bold: 1
tone: medium
---
Name | Stuart J Mackintosh
Function | Responsible person, Open Digital CC
Place and date of issue | To be completed at the 0.7.0 stable cut
Signature | (unsigned draft)
```
