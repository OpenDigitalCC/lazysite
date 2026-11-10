---
id: SM1429
title: "SM1429: the compliance records cover 0.16.10"
subtitle: "The gate's compliance check refuses 0.16.10 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.9. Both are walked against the 0.16.10 line and stamped 0.16.10; SM1422's entry and the walk's own are drafted for the release manager."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "the compliance check, which refuses a release whose records are behind its version (SM1306 to SM1419); release manager, ruling 229 (2026-11-10)"
area: release
status-note: "SHIPPED (0.16.10) on n808. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.10; SM1422's entry (ruling 229) and the walk's entry (SM1420, SM1421, SM1423 to SM1427) drafted, no trigger, not yet confirmed; one STRIDE row; UPGRADE.md's one 0.16.10 section; two defects found at the walk fixed (repair's shell use, the deploy's USER and DOMAIN), t/tools/626, 627."
---

# What was asked

The release gate runs the compliance check with the 0.16.10 release material written in.
With OBLIGATIONS.md `reviewed_at_version` and TECHNICAL-FILE.md `covers_version` at
0.16.9 it refuses, as the 0.16.2 to 0.16.9 gates did. The walk reads each record against
what 0.16.10 changes: the CHANGELOG's `## Unreleased` section and `git log
64d5c3c11..17a681a71`, 23 commits (SM1420 to SM1427, the line n799 to n807). The release
manager's ruling 229 (2026-11-10) rules how SM1422 ships.

# What it carries

- docs/SECURITY.md, SM1422's entry: the verdict adds ruling 229's answer. It ships in
  0.16.10, not security-critical, with no advisory, because the code is only in 0.16.9
  (edge), off by default and in no stable release. It is not marked confirmed.
- docs/SECURITY.md, a new entry dated 2026-11-10 for SM1420, SM1421, SM1423, SM1424,
  SM1425, SM1426 and SM1427, drafted for confirmation, no trigger. Each item was read
  against the code it names: the Hestia deploy (the registry entry, `install.pl
  --site-url`, `setup-sysop` as the site user, the fleet verbs' `--all`, ruling 231);
  `git` in the image and in the package's Recommends, and the declared modes the upgrade
  sets; the wording of a refused write and of `description:`; the signed-in marker's one
  writer (it carries no authority, and no server code reads it); output and docs. One
  STRIDE row, for the root-run Hestia deploy.
- docs/compliance/OBLIGATIONS.md, stamped 0.16.10: the register, threat-model, SBOM
  (strict, exit 0, 495 components, none more than at 0.16.9), fired-trigger and
  vulnerability-handling rows; one sentence on the SM1351 operate-side row; the "what a
  person must confirm" section for 0.16.10. docs/compliance/TECHNICAL-FILE.md, stamped
  0.16.10: the risk assessment current to 0.16.10, 1,797 test files. docs/POLICY.md:
  walked to 0.16.10.
- docs/architecture/security.md: a 0.16.10 section, with the cited functions and
  constants checked against the code.
- UPGRADE.md: the 0.16.10 notes are one section in 0.16.9's shape, what to do first and
  then "Smaller changes, nothing to do".

# Found at the walk

- 0.16.10 is edge, not security-critical (ruling 229 for SM1422; the rest fixes no
  vulnerability).
- `lazysite repair` ran the doctor (the check, the `--fix` run, the check again) as one
  string through the shell with the docroot and cgi-bin unquoted. Fixed in its own
  commit: list-form pipes (`_capture`); t/tools/626 repairs a docroot named with
  `;touch MARK` and `$(touch MARK2)` and fails without the change.
- The Hestia deploy checked USER and DOMAIN only by the docroot existing. Fixed in its
  own commit: DOMAIN a plain host name, USER a plain name and a user Hestia holds
  (`v-list-user`), exit 2 before anything is touched; t/tools/627 fails without the
  change.
- SM1427's deploy prints the claim link to the terminal of whoever runs it, as
  `setup-sysop` does by hand; it is a credential for 24 hours or one use. Left as it is
  and recorded as residual risk; the summary now says not to paste it into a ticket or a
  log.

# Tests

t/tools/626 and t/tools/627, each failing without its change. The rest is docs.
