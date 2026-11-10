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
status:              index - complete in coverage, walked row by row on 2026-11-10 against the 0.16.10 edge (the line's tip 17a681a71, 23 commits since the 0.16.9 walk); the two register entries for 0.16.10 (SM1422, and the walk's: SM1420, SM1421, SM1423 to SM1427) fire no trigger and are drafted by the developer agent, not yet confirmed by the release manager, with one STRIDE row added at the walk (the root-run Hestia deploy); 0.16.10 is edge and not security-critical (ruling 229); the 0.16.9 walk of 2026-11-10 against the 0.16.9 edge (the stack's tip 63e8f1970, 102 commits); the sixteen register entries for 0.16.9 written on their branches were confirmed by the release manager on 2026-11-10 (ruling 225), seven of them the assessments of a fired trigger, confirmed contained: SM1369 X4 and SM1351 (sign-in method; SM1351 with new-external-interface), SM1352 passkeys (new-authentication-method and new-external-interface), CryptX (new-dependency-with-authentication-logic), SM1363 web push and webhook (new-external-interface), SM1363's phone number and SM1364 (new-processing-of-restricted-data); the nine others fire none; no early third-party review, the OIDC grant mapping and the passkey paths named in the scope of the engagement ADR 0007 already requires; the one written at the walk (SM1418, SM1407, SM1404, SM1398, the container's tooling, the restack's wording), trust boundary 15 and the assets line restated and the nine 0.16.9 STRIDE rows the walk added are confirmed by the release manager on 2026-11-10 (ruling 226); the thirteen register entries for 0.16.8 for 0.16.8 written on their branches were confirmed by the release manager on 2026-11-08 (ruling 177), three of them the assessments of a fired trigger, confirmed contained: SM1414 (new-external-interface), SM1355 and SM1396 (new-processing-of-restricted-data); the one written at the walk (SM1400, SM1402, SM1404, SM1405, SM1409, SM1411), trust boundary 15 and the assets line restated and the three 0.16.8 STRIDE rows the walk added were confirmed by the release manager on 2026-11-08, with 0.16.8 edge and not security-critical (ruling 182); of the eight register entries for 0.16.7, SM1383 (new-external-interface, narrow) was confirmed by the release manager on 2026-11-07 (ruling 146); SM1381 (new-external-interface), SM1369 X7 part one, SM1390 (hardening, ruling 147), SM1387, SM1393 and SM1392, written on their branches and walked, and the one written at the walk (SM1385, SM1389, SM1391) were confirmed by the release manager on 2026-11-07 (rulings 149-152: SM1381 contained, ruling 150; SM1387's action no new interface, ruling 151; SM1392's listing, ruling 152), with the restated boundary 12 and the four 0.16.7 STRIDE rows (ruling 149); the twelve register entries for 0.16.6 were confirmed by the release manager on 2026-11-06: the ten written on their branches (rulings 134, 140; two assess a fired trigger: SM1369 new-external-interface, SM1362 new-processing-of-restricted-data), the one written at the walk (SM1375, SM1378; ruling 142) and the one for the 403 page's escaping (ruling 141), with trust boundary 15 and the three 0.16.6 STRIDE rows (ruling 142); the threat model rows and, at certified, the declaration are what a person confirms; the six register entries for 0.16.5 and the 2026-11-06 entry for 0.16.4 (SM1142) were confirmed on 2026-11-06 (rulings 125, 127); as are the threat model rows and, at certified, the declaration; the SM1303 (0.16.2) and SM1308/SM1309 (0.16.3) register entries, and the 2026-11-05 entry for the rest of 0.16.3, were accepted by the release manager on 2026-11-05 (rulings 65, 93)
covers_version:      0.16.10
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
Cybersecurity risk assessment | docs/SECURITY.md (STRIDE, ASVS L1, fifteen-boundary model and the significant-change register); docs/architecture/security.md | current to 0.16.10 - a manager cannot point a new OIDC map entry at a capability group (SM1422, ruling 229), and the root-run Hestia deploy, the fleet verbs' --all, the declared modes the upgrade sets and the signed-in marker's one writer (SM1423 to SM1427), all drafted for the release manager, none firing a trigger, with docs/architecture/security.md's 0.16.10 section; for 0.16.9, an extension's identity provider (SM1369 X4) and an outside OpenID Connect provider whose groups may grant (SM1351, ruling 186's first use), the sign-in-method trigger, SM1351 with new-external-interface; passkeys (SM1352, new-authentication-method and new-external-interface) and CryptX (new-dependency-with-authentication-logic); web push and webhook notices (SM1363, new-external-interface) and an account's phone number (new-processing-of-restricted-data); a table reading its rows from another system's API (SM1364, new-processing-of-restricted-data, ruling 190); an extension's endpoint, services, checks, manager pages and the one secrets store (X5, X6); identity as a value (SM297); the damaged-store refusals (SM1417, ruling 206); the shared container engine (SM1361, X7) and the beside layout's modes (T-115); all sixteen entries confirmed by the release manager on 10 Nov 2026 (ruling 225), with trust boundary 15 and the assets line restated and nine STRIDE rows added at the 0.16.9 walk, confirmed by the release manager on 2026-11-10 (ruling 226), and docs/architecture/security.md's 0.16.9 section; for 0.16.8, an extension's declared capabilities and actions (SM1369 X2), page sources and delivery handler types (X3; the Odoo type on `manage_connectors`, ruling 178) and asset hooks (X5's asset part), the first callers of boundary 15's loader, restated there; the offline kit (SM1396) and row history with undo (SM1355), each new-processing-of-restricted-data, contained by the purge at sign-out keyed to the login and by the daily `row-history-prune` job; the member content door (SM1414), new-external-interface; an anonymous public write binding (SM1395) and `owner_contact` retired (SM1412), hardenings; a notify handler naming a group (SM1413), a page's copy and `publish_copies` (SM1354), schedules and the sweep (SM1356; its removals audited, ruling 179), JSON-LD and the listings (SM1357) and two roles on an older site (SM1407), written on their branches; all thirteen confirmed by the release manager on 8 Nov 2026 (ruling 177); the smaller changes (SM1400, SM1402, SM1404, SM1405, SM1409, SM1411) added 8 Nov 2026 at the walk with three STRIDE rows, confirmed by the release manager on 8 Nov 2026 (ruling 182); for 0.16.7, Odoo's modules in the extension's payload lib (SM1369 X7 part one), the renewal step on the Odoo endpoint (SM1381), new-external-interface, both restated in boundary 12; the session cookie as an external contract (SM1383), new-external-interface in a narrow form, confirmed 7 Nov 2026 (ruling 146); another signed value is not a session (SM1390, hardening, ruling 147); a group deleted on every door once nothing uses it (SM1387); the roles and bundles on a pre-mark site (SM1393); a form's conf in the editor and over MCP (SM1392), written on their branches and walked 7 Nov 2026; a theme deleted by path, the check's prune and the schedule floor (SM1385, SM1389, SM1391) added 7 Nov 2026 at the walk, with four STRIDE rows; all eight entries and the rows confirmed by the release manager on 7 Nov 2026 (rulings 149-152); for 0.16.6, the hook loader (SM1369 X0, X1), new-external-interface, with trust boundary 15; the owner mail and acknowledgement (SM1362), new-processing-of-restricted-data; a token following its grant (SM1370), agent roles and a form's config (SM1371), the extension settings read (SM1373), Odoo's refusals (SM1374) and the record's actor (SM1366), the primary's reach (SM1372), the quarantine's email fields (SM1379) and the data endpoint's refusal (SM1377), written on their branches and walked 6 Nov 2026, those ten entries confirmed by the release manager on 6 Nov 2026 (rulings 134, 140); the 403 page's group list and a layout's engine requirement (SM1375, SM1378) added 6 Nov 2026 at the walk with three STRIDE rows, confirmed by the release manager on 6 Nov 2026 (ruling 142), and the 403 page's escaping (ruling 141), confirmed; for 0.16.5, a protected folder's history (SM1324) and the AI read audit (SM1325), each new processing of restricted data, domain grants and the group pin (SM1332-SM1334) and address profiles (SM1343-SM1345) added 5 Nov 2026 and walked 6 Nov 2026; a theme's served copies (SM1335, SM1336, SM1339) and the rest of 0.16.5 (the bad-URL blocker's exemptions, /login's session check, write_file's base version, the Odoo display name, the design guide, the public setup page, Odoo's not-kept fields, the ACL 403 page) added 6 Nov 2026, with two STRIDE rows; all six entries confirmed by the release manager on 6 Nov 2026 (rulings 125, 127); for 0.16.4, SM1142's rename (the upgrade step that moves a site to `extensions/`, the conf rewrite, and the wire's old spelling refused and its response keys renamed, ruling 95) added 6 Nov 2026, that entry confirmed on 6 Nov 2026 (ruling 127); for 0.16.3, a confined grant's walks (SM1308, SM1311, SM1312) and a rule inside another (SM1309, SM1313) added 4 Nov 2026, that entry accepted by the release manager on 5 Nov 2026; the rest of 0.16.3 (access, the engine's /docs manual, the theme upload over MCP, the Odoo settle capability, the deploy path) added 5 Nov 2026, that entry accepted by the release manager on 5 Nov 2026; SM1303's exposure (a theme archive's link in the served asset mirror) and SM1304's warning added 23 Oct 2026, that entry accepted on 5 Nov 2026; the 0.16.1 changes (the warm-fork parent, the stem-rule fix SM1257, the Odoo options and OOM 0.42, the Docker package) added 23 Oct 2026, those register entries confirmed by the release manager on 23 Oct 2026; the 0.11-0.15 changes and their entries confirmed on 21 Oct 2026
Applicable harmonised standards | docs/POLICY.md | current
Vulnerability handling processes | SECURITY.md (CVD intake); docs/adr/0007-pentest-deferral.md (SLAs, triggers) | PARTIAL - no dated remediation record; 0.16.2 is the first release cut security-critical (SM1305: its manifest declares it, so `upgrade --all --force-security` and, on a Hestia host, the updater's `--force-security` (SM1307) push it past every site's channel); from 0.16.3 a security release is cut on stable (SM1314) and the deploy hook passes `--force-security` itself (SM1315); 0.16.3, 0.16.4, 0.16.5, 0.16.6 and 0.16.7 are edge, not security-critical (0.16.6's SM1373 and 0.16.7's SM1390 each judged a hardening, not a fix, at their walks; SM1390 by ruling 147); 0.16.8 is edge and not security-critical (ruling 182; SM1395 and SM1412 hardenings); 0.16.9 is edge, not security-critical (ruling 226; SM1417 and T-115 hardenings). No early third-party review for 0.16.9 (ruling 225): the first engagement ADR 0007 requires is scoped to include the OIDC grant mapping (SM1351) and the passkey paths (SM1352)
Support-period statement | docs/POLICY.md; docs/compliance/OBLIGATIONS.md (absolute date) | current
SBOM | dist/config/sbom-deps.json; generated per release, CycloneDX, shipped in the tarball | current, strict gate - 495 components at 0.16.10, none more than at 0.16.9 (no shipped file or sbom-deps.json entry added); 495 at 0.16.9 (nineteen more: fifteen shipped files, `Lazysite::Crypto`, `Endpoint`, `Secrets`, `WebPush` and `Auth::Passkey`, `Lazysite::Odoo::Check`, the `oidc` extension's descriptor, module and endpoint, the three account components, Odoo's panel page, `lazysite-sites` and `front.conf.example`, and four sbom-deps.json entries, the first since 0.16.2: `Crypt::PK::ECC`, `Crypt::PK::RSA` and `Crypt::PK::Ed25519` for CryptX, and `Template::Filters`); 476 at 0.16.8 (thirteen more shipped files: `Lazysite::Extensions::Declared`, Odoo's `Actions` and `Hooks`, the processor part `extensions.pm`, the offline kit's descriptor, script and module, `PageCopy` and `Manager::PageCopy`, `Data::RowHistory`, `Data::Wizard`, `Data::Schedule` and `Data::StructuredData`; the Odoo helper and sign-in component renamed into `extensions/odoo/`, counted as before); 463 at 0.16.7 (one more shipped file, the group-reference walk `Lazysite::Auth::GroupRefs`; Odoo's fifteen modules renamed into `extensions/odoo/lib/`, counted as before; 462 at 0.16.6, the hook loader `Lazysite::Extensions::Hooks`; 461 at 0.16.5; sbom-deps.json unchanged since 0.16.2); OOM is declared as `libodoo-oom-perl`, and the 0.44 snapshot in t/vendor/oom (SM1346, was 0.42, SM1247) is for the tests: it is in the tarball with t/ and is never installed
Conformity assessment records | docs/review/*-eight-dimension/ (four full reviews, the last of 0.10.9); docs/review/0.13.1-daemon/; docs/review/2026-10-07-sm869-adversarial-review.md; the SM1181 security review and SM1226's threat table in docs/feature-requests | the last full review is of 0.10.9
Declaration of Conformity | docs/DECLARATION-OF-CONFORMITY.md | OPEN - draft restamped 0.16.0, unsigned; signed at the certified cut
Test evidence | t/ (1,795 test files at 0.16.10); coverage floors in dist/config/coverage-floor and coverage-floor-groups; bench baseline | coverage runs at a stable cut; the bench re-capture is due at the next stable cut
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
