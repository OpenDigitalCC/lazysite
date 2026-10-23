---
id: SM1306
title: "SM1306: the compliance records cover 0.16.2"
subtitle: "0.16.2 is a security release cut from main straight after 0.16.1, and the gate's compliance check refuses with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.1. Both are walked against SM1303-SM1305 and stamped 0.16.2."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the compliance check run alone for 0.16.2 (tmp/n738-compliance-check.sh): two blocking findings, as the 0.16.1 gate had (SM1269)"
area: release
status-note: "SHIPPED (PENDING) on n738: docs only. OBLIGATIONS.md reviewed_at_version and TECHNICAL-FILE.md covers_version 0.16.2; POLICY.md's technical-file row; docs/architecture/security.md on the zip upload. The register entry is SM1303's. content_sha is left for the release manager to stamp at sign-off."
---

# What was asked

Run alone, as the gate runs it on a fresh clone with the 0.16.2 release material
written in, the compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.1, cutting 0.16.2 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.1, cutting 0.16.2 - walk docs/compliance/TECHNICAL-FILE.md and update it

The walk reads each record against what 0.16.2 changes: `git log d167c6d28..` on
this branch, SM1303 to SM1305 and nothing else (ruling 41b).

# What it carries

- docs/compliance/OBLIGATIONS.md, stamped 0.16.2: the register row names the SM1303
  entry (a draft, no trigger fired, a bypass of boundary 6) beside the 0.16.1
  entries; the threat model row names SM1303's STRIDE row and the architecture
  section; the SBOM row the strict run on the 0.16.2 tree (exit 0, 455 components,
  the manifest built `--security-critical`); the technical-file row; the
  vulnerability-handling row records 0.16.2 as a security release (SM1305, pushed
  with `--force-security`); a new operate-side row for SM1304 (remove a planted
  link and rotate the secret); and the "what a person must confirm" section is
  for 0.16.2. Ruling 44 (2026-10-23) settled what it first listed as open: SM1303
  has no known exploitation, so no CRA Article 14 notification and no advisory.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.2: the risk assessment current to
  0.16.2, the vulnerability-handling row naming the first security-critical
  release, 455 SBOM components and 1,553 test files at 0.16.2.
- docs/POLICY.md: the technical file is walked to 0.16.2.
- docs/architecture/security.md: the zip upload and the served asset mirror.

Sections with nothing to change: the Declaration of Conformity (unsigned, 0.16.0),
signed releases, OpenChain, the bench baseline, the restore rehearsal, CE marking
and the support period; the technical file's description, design, production,
standards, support and declaration rows. SM1305 is release tooling and touches no
trust boundary.

# Tests

The compliance check run alone on the branch (tmp/n738-compliance-check.sh): with
the records at 0.16.1 it refuses on the two rows above; walked, it passes (exit 0),
with the two warnings that block only at certified (the declaration, the restore
rehearsal).
