---
title: "lazysite - technical documentation (CRA Annex VII)"
subtitle: "An index over evidence that already exists, kept current as a by-product rather than assembled later."
brand: plain
standard-margins: true
---

# What this file is, and why it is an index

Regulation (EU) 2024/2847 Annex VII requires technical documentation
describing the product, its design and development, and its
vulnerability-handling processes, sufficient to demonstrate conformity.

This file is **an index, not a narrative**. Nearly everything Annex VII asks
for already exists in this repository as a by-product of how the project works
- four eight-dimension reviews, ADRs recording every architectural decision and
its cause, a per-release SBOM under a strict gate, a threat model, a changelog
that explains causes rather than listing changes. Written as prose it would
duplicate all of that and start rotting immediately.

::: widebox
**Why start it now rather than before the deadline.** Assembled today it is a
short document over artefacts already in the tree, and stays current because
the artefacts do. Assembled in 2027 it is an archaeology exercise across three
release lines, reconstructing decisions from commits. This is the retrofit
asymmetry the framework is built on: cheap now, expensive later, and the cost
rises monotonically.
:::

```yaml
status:              index - complete in coverage, not yet reviewed as a whole
covers_version:      0.10.8
ce_marking_due:      2027-12-11
owner:               release manager
```

# Annex VII coverage

```datatable
columns: Annex VII requirement | Where it lives | State
widths: 5cm | X | 2cm
bold: 1
tone: medium
text: 2
---
General description: intended purpose, versions, product form | docs/FEATURES.md; README.md; CHANGELOG.md | current to 0.9.14 - see review D7 F7.1
Design and development: architecture, components | docs/architecture/*.md; docs/adr/*.md (ADRs record decision AND cause) | current
Production and monitoring processes | docs/development.md; tools/release.sh; docs/RELIABILITY.md | current
Cybersecurity risk assessment | docs/SECURITY.md (STRIDE, ASVS L1); docs/architecture/security.md | current to 0.10.8
Applicable harmonised standards | docs/POLICY.md | current
Vulnerability handling processes | SECURITY.md (CVD intake); docs/adr/0007-pentest-deferral.md (SLAs, triggers) | PARTIAL - no dated remediation record
Support-period statement | docs/POLICY.md; docs/compliance/OBLIGATIONS.md (absolute date) | current
SBOM | dist/config/sbom-deps.json; generated per release, CycloneDX, shipped in the tarball | current, strict gate
Conformity assessment records | docs/review/*-eight-dimension/ (four full reviews) | current to 0.10.8
Declaration of Conformity | docs/DECLARATION-OF-CONFORMITY.md | OPEN - stamped 0.8.0, unsigned
Test evidence | t/ (356 files); coverage floors in dist/config/coverage-floor; bench baseline | current
```

# Known gaps

Recorded here rather than left for a later reader to discover:

Vulnerability remediation record
: ADR 0007 declares remediation SLAs (critical 72h, high 30d, medium 90d, low
  180d) and nothing records whether any has been met. A dated register is
  tracked in `docs/compliance/OBLIGATIONS.md`.

Declaration of Conformity
: unsigned and stamped 0.8.0 while three later stable releases have shipped.

General description currency
: `docs/FEATURES.md` stops at 0.9.14.

Signed releases
: not applied, and cannot be applied retroactively.

# Maintenance

This file is walked at every release by
`tools/lazysite-compliance.pl --check`, which fails the gate when
`covers_version` is behind the version being cut. Keeping it current is
therefore a release step and not an annual exercise - which is the entire
argument for starting it as an index.
