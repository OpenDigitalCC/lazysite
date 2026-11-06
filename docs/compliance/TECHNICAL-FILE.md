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
status:              index - complete in coverage, walked row by row on 2026-11-06 against the 0.16.6 edge (the stack's tip 41c47b006, 36 commits); the twelve register entries for 0.16.6 were confirmed by the release manager on 2026-11-06: the ten written on their branches (rulings 134, 140; two assess a fired trigger: SM1369 new-external-interface, SM1362 new-processing-of-restricted-data), the one written at the walk (SM1375, SM1378; ruling 142) and the one for the 403 page's escaping (ruling 141), with trust boundary 15 and the three 0.16.6 STRIDE rows (ruling 142); the threat model rows and, at certified, the declaration are what a person confirms; the six register entries for 0.16.5 and the 2026-11-06 entry for 0.16.4 (SM1142) were confirmed on 2026-11-06 (rulings 125, 127); as are the threat model rows and, at certified, the declaration; the SM1303 (0.16.2) and SM1308/SM1309 (0.16.3) register entries, and the 2026-11-05 entry for the rest of 0.16.3, were accepted by the release manager on 2026-11-05 (rulings 65, 93)
covers_version:      0.16.6
content_sha:         148b3776ec692b5c
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
General description: intended purpose, versions, product form | docs/FEATURES.md; README.md; CHANGELOG.md; the product forms in docs/IMPLEMENTOR.md (tarball, debs, Hestia, and from 0.16.1 the Docker Compose package, installers/docker/README.md) | current - checked at each release by tools/lazysite-compliance.pl
Design and development: architecture, components | docs/architecture/*.md; docs/adr/*.md (ADRs record decision AND cause) | current
Production and monitoring processes | docs/development.md; tools/release.sh; docs/RELIABILITY.md | current
Cybersecurity risk assessment | docs/SECURITY.md (STRIDE, ASVS L1, fifteen-boundary model and the significant-change register); docs/architecture/security.md | current to 0.16.6 - the hook loader (SM1369 X0, X1), new-external-interface, with trust boundary 15; the owner mail and acknowledgement (SM1362), new-processing-of-restricted-data; a token following its grant (SM1370), agent roles and a form's config (SM1371), the extension settings read (SM1373), Odoo's refusals (SM1374) and the record's actor (SM1366), the primary's reach (SM1372), the quarantine's email fields (SM1379) and the data endpoint's refusal (SM1377), written on their branches and walked 6 Nov 2026, those ten entries confirmed by the release manager on 6 Nov 2026 (rulings 134, 140); the 403 page's group list and a layout's engine requirement (SM1375, SM1378) added 6 Nov 2026 at the walk with three STRIDE rows, confirmed by the release manager on 6 Nov 2026 (ruling 142), and the 403 page's escaping (ruling 141), confirmed; for 0.16.5, a protected folder's history (SM1324) and the AI read audit (SM1325), each new processing of restricted data, domain grants and the group pin (SM1332-SM1334) and address profiles (SM1343-SM1345) added 5 Nov 2026 and walked 6 Nov 2026; a theme's served copies (SM1335, SM1336, SM1339) and the rest of 0.16.5 (the bad-URL blocker's exemptions, /login's session check, write_file's base version, the Odoo display name, the design guide, the public setup page, Odoo's not-kept fields, the ACL 403 page) added 6 Nov 2026, with two STRIDE rows; all six entries confirmed by the release manager on 6 Nov 2026 (rulings 125, 127); for 0.16.4, SM1142's rename (the upgrade step that moves a site to `extensions/`, the conf rewrite, and the wire's old spelling refused and its response keys renamed, ruling 95) added 6 Nov 2026, that entry confirmed on 6 Nov 2026 (ruling 127); for 0.16.3, a confined grant's walks (SM1308, SM1311, SM1312) and a rule inside another (SM1309, SM1313) added 4 Nov 2026, that entry accepted by the release manager on 5 Nov 2026; the rest of 0.16.3 (access, the engine's /docs manual, the theme upload over MCP, the Odoo settle capability, the deploy path) added 5 Nov 2026, that entry accepted by the release manager on 5 Nov 2026; SM1303's exposure (a theme archive's link in the served asset mirror) and SM1304's warning added 23 Oct 2026, that entry accepted on 5 Nov 2026; the 0.16.1 changes (the warm-fork parent, the stem-rule fix SM1257, the Odoo options and OOM 0.42, the Docker package) added 23 Oct 2026, those register entries confirmed by the release manager on 23 Oct 2026; the 0.11-0.15 changes and their entries confirmed on 21 Oct 2026
Applicable harmonised standards | docs/POLICY.md | current
Vulnerability handling processes | SECURITY.md (CVD intake); docs/adr/0007-pentest-deferral.md (SLAs, triggers) | PARTIAL - no dated remediation record; 0.16.2 is the first release cut security-critical (SM1305: its manifest declares it, so `upgrade --all --force-security` and, on a Hestia host, the updater's `--force-security` (SM1307) push it past every site's channel); from 0.16.3 a security release is cut on stable (SM1314) and the deploy hook passes `--force-security` itself (SM1315); 0.16.3, 0.16.4, 0.16.5 and 0.16.6 are edge, not security-critical (0.16.6's SM1373 judged a hardening, not a fix, at its walk)
Support-period statement | docs/POLICY.md; docs/compliance/OBLIGATIONS.md (absolute date) | current
SBOM | dist/config/sbom-deps.json; generated per release, CycloneDX, shipped in the tarball | current, strict gate - 462 components at 0.16.6 (one more shipped file, the hook loader `Lazysite::Extensions::Hooks`; 461 at 0.16.5; sbom-deps.json unchanged since 0.16.2); OOM is declared as `libodoo-oom-perl`, and the 0.44 snapshot in t/vendor/oom (SM1346, was 0.42, SM1247) is for the tests: it is in the tarball with t/ and is never installed
Conformity assessment records | docs/review/*-eight-dimension/ (four full reviews, the last of 0.10.9); docs/review/0.13.1-daemon/; docs/review/2026-10-07-sm869-adversarial-review.md; the SM1181 security review and SM1226's threat table in docs/feature-requests | the last full review is of 0.10.9
Declaration of Conformity | docs/DECLARATION-OF-CONFORMITY.md | OPEN - draft restamped 0.16.0, unsigned; signed at the certified cut
Test evidence | t/ (1,645 test files at 0.16.6); coverage floors in dist/config/coverage-floor and coverage-floor-groups; bench baseline | coverage runs at a stable cut; the bench re-capture is due at the next stable cut
```

# Known gaps

Recorded here rather than left for a later reader to discover:

Vulnerability remediation record
: ADR 0007 declares remediation SLAs (critical 72h, high 30d, medium 90d, low
  180d); the dated register that evidences them is tracked in
  `docs/compliance/OBLIGATIONS.md` and stays for the certified release.

Declaration of Conformity
: restamped to 0.16.0 and unsigned; the release manager signs it at the certified cut.

Signed releases
: not applied, and cannot be applied retroactively; stays for the certified release.

Review of the current line
: the last full eight-dimension review is of 0.10.9; 0.11 to 0.16.1 are covered by the 0.13.1 daemon review, the 2026-10-07 adversarial review and the security reviews inside feature filings (SM1181's, and SM1226's threat table for the warm-forked endpoint). Whether the certified cut wants a fresh full review is for the release manager.

# Maintenance

This file is walked at every release by
`tools/lazysite-compliance.pl --check`, which fails the gate when
`covers_version` is behind the version being cut. Keeping it current is
therefore a release step and not an annual exercise - which is the entire
argument for starting it as an index.
