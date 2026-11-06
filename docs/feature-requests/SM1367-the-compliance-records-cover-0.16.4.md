---
id: SM1367
title: "SM1367: the compliance records cover 0.16.4"
subtitle: "The gate's compliance check refuses 0.16.4 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.3. Both are walked against SM1142, the release's one change, and stamped 0.16.4, and the register has an entry drafted for the rename and its upgrade step."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "the compliance check run alone for 0.16.4 (tmp/n755-compliance-check.sh): two blocking findings, as the 0.16.2 and 0.16.3 gates had (SM1306, SM1337)"
area: release
status-note: "SHIPPED (PENDING) on n755: docs only. OBLIGATIONS.md reviewed_at_version and TECHNICAL-FILE.md covers_version 0.16.4; a drafted register entry and STRIDE row for SM1142; architecture notes; a new operate-side row. content_sha is left for the release manager to stamp at sign-off."
---

# What was asked

Run alone, as the gate runs it on a fresh clone with the 0.16.4 release material
written in, the compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.3, cutting 0.16.4 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.3, cutting 0.16.4 - walk docs/compliance/TECHNICAL-FILE.md and update it

Those two rows are the check's only blocking findings below certified. The walk reads
each record against what 0.16.4 changes: `git log d116279b1..7583a1c28`, SM1142's
slices S1-S4 and the fixes on them (ruling 63: 0.16.4 is SM1142 alone). The other
commits in the range file SM1350-SM1366 and change no code.

# What it carries

- docs/SECURITY.md, a new entry dated 2026-11-06 for SM1142, drafted by the developer
  agent for the release manager's confirmation: the one-time upgrade step
  `extensions-rename` (it moves files and re-points links in every site's tree, on
  HestiaCP after the root-run deploy's part, and decides which extensions stay on, the
  login rate limiter among them), the old wire spelling refused by name, and the
  response keys renamed for an external reader (ruling 95). It finds no ADR 0007
  trigger fired and names the residual risk: the references the upgrade cannot see,
  and the audit's action names, `extension-*` from 0.16.4.
- docs/SECURITY.md, a STRIDE row (Denial of service): a list or entry left under the
  old spelling reads as off, the rate limiter among them, and the controls on it.
- docs/compliance/OBLIGATIONS.md, stamped 0.16.4: the register, threat-model, SBOM
  (exit 0, 459 components) and technical-file rows; the operate-side register and
  vulnerability-handling rows; a new operate-side row for the references the upgrade
  cannot see; the "what a person must confirm" section for 0.16.4.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.4: the risk assessment current to
  0.16.4, 0.16.4 edge and not security-critical, 459 SBOM components and 1,596 test
  files at 0.16.4.
- docs/POLICY.md: the technical file is walked to 0.16.4.
- docs/architecture/security.md: extensions on disk and the step that moves a site to
  them.

Sections with nothing to change: the Declaration of Conformity (unsigned, 0.16.0),
signed releases, OpenChain, the bench baseline, the restore rehearsal, CE marking
and the support period. In the technical file: the description, design, production,
standards, support and declaration rows. No trust boundary is added.

# Found at the walk

- The audit's action names for the seven extension actions are `extension-*` from
  0.16.4, where every earlier row says `plugin-*` (SM831 kept the canonical name so
  that a reader filtering on it would not stop matching). The CHANGELOG and UPGRADE.md
  do not name it; the register entry, the operate-side row and the 0.16.4 notes do.

# Tests

The compliance check run alone on the branch (tmp/n755-compliance-check.sh): with
the records at 0.16.3 it refuses on the two rows above. Walked, it passes (exit 0),
with the two warnings that block only at certified (the declaration, the restore
rehearsal). The SBOM strict check on the same stage exits 0 with 459 components.
