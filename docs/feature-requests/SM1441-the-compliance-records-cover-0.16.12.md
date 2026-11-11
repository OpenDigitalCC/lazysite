---
id: SM1441
title: "SM1441: the compliance records cover 0.16.12"
subtitle: "The gate's compliance check refuses 0.16.12 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.11. Both are walked against the 0.16.12 line, the second beta, and stamped 0.16.12; the three register entries await the release manager."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "the compliance check, which refuses a release whose records are behind its version (SM1306 to SM1436); release manager, ruling 242 (2026-11-11)"
area: release
status-note: "SHIPPED (PENDING) on n820. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.12, channel beta (ruling 242); SM1439's entry, SM1440's entry and the walk's entry (SM1438's record), no trigger, drafted for the release manager's confirmation; one STRIDE row; UPGRADE.md's one 0.16.12 section. The restore-rehearsal row stays OPEN. Docs only."
---

# What was asked

The release gate runs the compliance check with the 0.16.12 release material written in. With
OBLIGATIONS.md `reviewed_at_version` and TECHNICAL-FILE.md `covers_version` at 0.16.11 it
refuses, as the 0.16.2 to 0.16.11 gates did. The walk reads each record against what 0.16.12
changes: the CHANGELOG's `## Unreleased` section and `git log b050272f9..2920a8f8a`, 10 commits
(SM1438 on n816, SM1439 on n817 and SM1440 on n818, stacked on the 0.16.11 release commit).
Ruling 242 (2026-11-11) makes 0.16.12 a second beta: cut with `--beta` from 0.16.11 plus the beta
field-pass fixes, the code the 0.17.0 stable is promoted from (rulings 227, 242), with the
feature freeze holding (ruling 228).

# What it carries

- docs/SECURITY.md, a new entry dated 2026-11-11 for SM1439: `install.pl --restore-full` lays the
  engine's entry points from the release, applies the serving group and the modes as an install
  does, and writes the install state (ruling 239). It names the trust boundary (a full backup
  carries the auth secrets; the restore is a system-user operation, in no manager or network
  door), what the restore now writes from the release and what comes from the tarball (data only,
  with the backup's state entries for seed and content files), and one residual: the setgid chmod
  and the root ownership repair follow a symlinked `lazysite/` in a tarball. No ADR 0007
  trigger.
- docs/SECURITY.md, an entry for SM1440: refusals name the unix user to run as, the check says ok
  only about what it read, no `--fix` hint with nothing to fix, and the one behaviour change, a
  group limit on a group that does not exist is refused. A small disclosure (the unix user's
  name, to a manager when the web process cannot read a store) is named. No trigger.
- docs/SECURITY.md, the walk's entry for 0.16.12: SM1438's rehearsal record, with each change's
  assessment; no trigger. One STRIDE row, for the full restore.
- docs/compliance/OBLIGATIONS.md, stamped 0.16.12: the register, threat-model, SBOM,
  fired-trigger and vulnerability-handling rows; one operate-side row (a restore script needs the
  new flags); the "what a person must confirm" section for 0.16.12. The restore-rehearsal row
  stays OPEN. docs/compliance/TECHNICAL-FILE.md, stamped 0.16.12: the risk assessment current to
  0.16.12, 1,813 test files. docs/POLICY.md: walked to 0.16.12.
- docs/architecture/security.md: a 0.16.12 section.
- UPGRADE.md: the 0.16.12 notes are one section in 0.16.11's shape, the beta stated first, then
  what to do (a restore script's flags), then "Smaller changes, nothing to do".

# The beta

- 0.16.12 is the second beta (ruling 242), not security-critical: no change in it fixes a known
  vulnerability. The channel changes nothing in the compliance check beyond the edge cut: the same
  two version stamps block, and the Declaration of Conformity, the restore rehearsal and the
  bench baseline stay advisory below stable and certified.
- The restore rehearsal is the one open item (rulings 241, 242). The 11 Nov 2026 row in
  docs/RELIABILITY.md stands as the record of the restore gap and is not changed. It is rerun by
  the developer on this host against the shipped 0.16.12 tarball, now that the restore is one
  command, and confirmed by the release manager before the 0.17.0 stable cut. No evidence for it
  is written here.

# Tests

None. The records are docs. The gates are the lint dir, the precheck and the compliance check run
with `--channel beta`.
