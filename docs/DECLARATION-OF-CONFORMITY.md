---
title: "lazysite - Declaration of Conformity"
subtitle: "EU declaration of conformity per Regulation (EU) 2024/2847 (Cyber Resilience Act) - UNSIGNED DRAFT, for the 0.16.0 stable"
brand: plain
---

# Status

::: widebox
**UNSIGNED DRAFT.** This declaration is not signed. The release manager signs it,
at the certified cut (ADR 0010); the developer agent restamped the draft on 20 October
2026 and signs nothing. Until it is signed, `docs/POLICY.md` remains the posture of
record and this document claims no conformity not yet in place.
:::

This is the Declaration of Conformity draft for the 0.16.0 stable of
lazysite. Its code is the code of 0.15.15, walked clean (release manager,
20 October 2026: "0.15.15, after its walk"; 21 October 2026: the stable is cut from main
before the next batch lands). It was
prepared at 0.8.0 and carried forward through the stable releases since;
it is now stamped to the candidate and its evidence is refreshed. It becomes the
declaration of record when the version and dates are finalised and the responsible
person signs at the certified cut. Legal review is required before any external use.
Signed releases and the vulnerability remediation register stay for the certified
release (release manager, 20 October 2026).

# 1. Product identification

```datatable
columns: Field | Value
widths: 5cm | X
bold: 1
tone: medium
---
Product | lazysite - static site builder with authenticated authoring (web manager, WebDAV, control API/MCP)
Version | 0.16.0 - the stable (the code of 0.15.15); to be finalised at the certified cut
Unique identification | git tag `v0.16.0`; release tarball `dist/lazysite-0.16.0.tar.gz` with `.sha256` sidecar; embedded `release-manifest.json` and `sbom.json` (CycloneDX)
Release channel | stable candidate (`release.sh --final`); the declaration of record attaches to a certified cut (`release.sh --certified`, ADR 0010)
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
Secure by design/default; risk-based development (Part I) | The STRIDE/ASVS L1 threat model in `docs/SECURITY.md` (thirteen trust boundaries; the 0.11-0.15 trust changes added 20 October 2026); the mechanism narrative in `docs/architecture/security.md`; the mechanical release gates (full suite, lint, secrets, strict SBOM) recorded per release
Protection from unauthorised access; data confidentiality and integrity | The capability model and controls verified in `docs/SECURITY.md` (ADRs 0001/0003; per-file ACLs; checked writes; anonymise-at-write access log)
Availability and resilience | The reliability declaration in `docs/RELIABILITY.md` (SLOs, error budget, RTO/RPO, failure-mode test mapping, restore rehearsals)
Vulnerability handling (Part II); coordinated disclosure | The CVD policy in the repo-root `SECURITY.md` (private reporting channel, acknowledgement and fix timelines); the significant-change assessment register in `docs/SECURITY.md` (entries through 0.15.15, drafted by the developer agent and awaiting the release manager's confirmation); the dated remediation register that evidences the ADR 0007 timelines stays for the certified release
SBOM | `sbom.json` shipped in the release tarball (CycloneDX, per-file SHA-256, SPDX licence ids), regenerated per release behind the strict drift gate (`tools/manifest-to-sbom.pl --strict`)
Security updates; support period | Five years from the first stable release (0.7.0), ending 2031-07-10, security fixes on the stable channel - declared in `docs/POLICY.md` ("Support period"); delivery via the edge/stable/certified channel mechanism (ADR 0005, ADR 0010)
Obligations status overview | The CRA Article 13 obligations table in `docs/POLICY.md` - the posture of record for what is in place, drafted and pending; the dated register in `docs/compliance/OBLIGATIONS.md` (walked to 0.15.15) and the Annex VII index in `docs/compliance/TECHNICAL-FILE.md`
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
Place and date of issue | To be completed at the certified cut
Signature | (unsigned draft)
```
