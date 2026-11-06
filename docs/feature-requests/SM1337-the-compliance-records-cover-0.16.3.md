---
id: SM1337
title: "SM1337: the compliance records cover 0.16.3"
subtitle: "The gate's compliance check refuses 0.16.3 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.2. Both are walked against the 0.16.3 batch and stamped 0.16.3, the register records ruling 65's acceptance, and one entry is drafted for what no entry covered."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-05
raised-by: "the compliance check run alone for 0.16.3 (tmp/n748-compliance-check.sh): two blocking findings, as the 0.16.1 and 0.16.2 gates had (SM1269, SM1306)"
area: release
status-note: "SHIPPED (0.16.3) on n748: docs only. OBLIGATIONS.md reviewed_at_version and TECHNICAL-FILE.md covers_version 0.16.3; the SM1303, SM1308 and SM1309 register entries accepted (ruling 65); a drafted entry for the rest of 0.16.3; architecture notes and an OPERATOR.md paragraph for SM1313. content_sha is left for the release manager to stamp at sign-off."
---

# What was asked

Run alone, as the gate runs it on a fresh clone with the 0.16.3 release material
written in, the compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.2, cutting 0.16.3 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.2, cutting 0.16.3 - walk docs/compliance/TECHNICAL-FILE.md and update it

Those two rows are the check's only blocking findings below certified. The register
row already passed (the SM1308/SM1309 entry names 0.16.3). The walk reads each record
against what 0.16.3 changes: `git log 2eabff558..c093a5e89`, the batch held while
0.16.2 went out as a security release.

Ruling 65 (2026-11-05): the drafted register entries for SM1303 (0.16.2), SM1308 and
SM1309 (0.16.3) are accepted.

# What it carries

- docs/SECURITY.md: the SM1303 entry and the SM1308/SM1309 entry (with SM1311-SM1313)
  read "confirmed by the release manager on 2026-11-05 (ruling 65)", and each verdict
  "accepted, confirmed by the release manager on 2026-11-05", in the shape SM1269 used
  for the 23 October acceptance. The SM1308/SM1309 entry no longer leaves a security
  release open: 0.16.3 is cut edge, not security-critical. Ruling 94 (2026-11-05):
  no exploitation of either is known, so no CRA Article 14 notification and no
  advisory; the 0.16.3 notes carry what was exposed and what to do.
- docs/SECURITY.md, a new entry dated 2026-11-05 for the rest of 0.16.3 that moves a
  control, drafted by the developer agent and accepted by the release manager on
  2026-11-05 (ruling 93): access (SM1270, SM1272, SM1273, SM1294,
  SM1310), the served tree (SM1283-SM1286, the engine's /docs manual), the theme
  upload reachable with a token over MCP (SM1291, SM1290), the Odoo unknown-run
  settle capability and the address bit (SM1275-SM1280), `/odoo-signin`'s return
  (SM1295, SM1299), and the release path (SM1314, SM1315). It finds no ADR 0007 trigger
  fired, as the 0.16.1 entry for its access and rollout changes did. It names what is
  left out and why.
- docs/compliance/OBLIGATIONS.md, stamped 0.16.3: the register, threat-model, SBOM
  (exit 0, 458 components) and technical-file rows. The two operate-side register and
  vulnerability-handling rows. A new operate-side row for SM1313: review each rule
  wider than its enclosing rule. The "what a person must confirm" section is for
  0.16.3.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.3: the risk assessment current to
  0.16.3, the vulnerability-handling row (SM1314, SM1315), 458 SBOM components and
  1,593 test files at 0.16.3.
- docs/POLICY.md: the technical file is walked to 0.16.3.
- docs/architecture/security.md: a confined grant's walks and a rule inside another;
  the engine's /docs manual and pages beside a moved engine tree; the zip upload over
  MCP; a write whose answer never came; the shared sign-in return.
- docs/OPERATOR.md: "A rule wider than the rule around it is left for you", the
  operate-side row's source.

Sections with nothing to change: the Declaration of Conformity (unsigned, 0.16.0),
signed releases, OpenChain, the bench baseline, the restore rehearsal, CE marking
and the support period. In the technical file: the description, design, production,
standards, support and declaration rows. No trust boundary is added.

# Tests

The compliance check run alone on the branch (tmp/n748-compliance-check.sh): with
the records at 0.16.2 it refuses on the two rows above. Walked, it passes (exit 0),
with the two warnings that block only at certified (the declaration, the restore
rehearsal). The SBOM strict check on the same stage exits 0 with 458 components.
