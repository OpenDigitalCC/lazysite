---
id: SM1368
title: "SM1368: the compliance records cover 0.16.5"
subtitle: "The gate's compliance check refuses 0.16.5 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.4. Both are walked against the 0.16.5 stack's ten branches and stamped 0.16.5; the four register entries the branches wrote are walked, two of them found to fire a trigger, and two more are drafted."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "the compliance check run alone for 0.16.5 (tmp/n756-compliance-check.sh): two blocking findings, as the 0.16.2, 0.16.3 and 0.16.4 gates had (SM1306, SM1337, SM1367)"
area: release
status-note: "SHIPPED (PENDING) on n756: docs only. OBLIGATIONS.md reviewed_at_version and TECHNICAL-FILE.md covers_version 0.16.5; the four branch-written register entries walked, SM1324 and SM1325 recorded as firing new-processing-of-restricted-data; two drafted entries and two STRIDE rows; architecture notes; two operate-side rows; UPGRADE.md's 0.16.5 entry. content_sha is left for the release manager to stamp at sign-off."
---

# What was asked

Run alone, as the gate runs it on a fresh clone with the 0.16.5 release material
written in, the compliance check refused:

    FAIL obligations register: reviewed_at_version is 0.16.4, cutting 0.16.5 - walk docs/compliance/OBLIGATIONS.md and update it
    FAIL technical file: covers_version is 0.16.4, cutting 0.16.5 - walk docs/compliance/TECHNICAL-FILE.md and update it

Those two rows are the check's only blocking findings below certified. The walk reads
each record against what 0.16.5 changes: `git log 97d64789c..046dec59c`, 47 commits on
ten branches (SM1321, SM1322, SM1324, SM1325, SM1327, SM1328, SM1330, SM1332-SM1336,
SM1339-SM1347, SM1365).

# What it carries

- docs/SECURITY.md, the four entries written on their branches (2026-11-05: SM1324,
  SM1325, SM1332-SM1334, SM1343-SM1345) walked against the code, each with a "walked"
  note. SM1324 (a protected folder's history, a second copy of protected content) and
  SM1325 (agents' accounts, paths and addresses in a log) each fire ADR 0007's
  new-processing-of-restricted-data, as SM286 and SM1219 fired it; neither said so as
  filed. SM1325's entry had no verdict; a proposed one is added.
- docs/SECURITY.md, a new entry dated 2026-11-06 for SM1335, SM1336 and SM1339: a
  theme's served copies follow its source on every write, and are refused to every
  writer. No trigger fired.
- docs/SECURITY.md, a new entry dated 2026-11-06 for the rest of 0.16.5 that moves a
  control: SM1321 (the bad-URL blocker's exemptions), SM1322 (/login's session check),
  SM1327, SM1328, SM1340, SM1341 (Connect an AI assistant made public), SM1347, SM1365.
  No trigger fired. SM1330, SM1342 and SM1346 move no control.
- docs/SECURITY.md, two STRIDE rows: Elevation of privilege, a theme's source
  re-mirrored on every write (SM1335); Denial of service, the blocker's loopback
  exemption behind a front end `trusted_proxies` does not cover (SM1321).
- docs/compliance/OBLIGATIONS.md, stamped 0.16.5: the register, threat-model, SBOM
  (exit 0, 461 components) and technical-file rows; the operate-side register and
  vulnerability-handling rows; two new operate-side rows (the rules and template calls
  the address-profile check names; a folder's history and the read audit where a site
  turns them on); the "what a person must confirm" section for 0.16.5.
- docs/compliance/TECHNICAL-FILE.md, stamped 0.16.5: the risk assessment current to
  0.16.5, 0.16.5 edge and not security-critical, 461 SBOM components, the OOM test
  snapshot at 0.44, and 1,626 test files at 0.16.5.
- docs/POLICY.md: the technical file is walked to 0.16.5.
- docs/architecture/security.md: protected history, the read audit, served theme
  copies, the blocker's exemptions, the sign-in check, the ACL 403 page and the public
  setup page.
- UPGRADE.md: the 0.16.5 entry (address profiles, the blocker and `trusted_proxies`, a
  site's own `login.md`, theme copies, the public setup page).

Sections with nothing to change: the Declaration of Conformity (unsigned, 0.16.0),
signed releases, OpenChain, the bench baseline, the restore rehearsal, CE marking and
the support period. No trust boundary is added.

# Found at the walk

- The two fired triggers above, recorded in their entries and in OBLIGATIONS.md.
- The bad-URL blocker's loopback exemption: `trusted_proxies`' default trusts the
  private ranges, not loopback, so on a site behind a front end on the same host every
  visitor is loopback and the blocker counts nothing; `lazysite check` warns about an
  uncovered front end only where address rules are in use. UPGRADE.md says to name such
  a front end.
- SM1332's entry puts a question to the release manager (whether an account granted the
  primary should reach the other domains' folders under it) with no ruling on record in
  the filings; carried to the confirmation list.
- Three CHANGELOG entries carried a superseded fragment from their rework (SM1325, SM1344,
  SM1345); the fragments are removed and the entries separated.

# Tests

The compliance check run alone on the branch (tmp/n756-compliance-check.sh): with the
records at 0.16.4 it refuses on the two rows above. The SBOM strict check on the same
stage exits 0 with 461 components; sbom-deps.json is unchanged in the range.
