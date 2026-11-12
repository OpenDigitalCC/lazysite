---
id: SM1448
title: "SM1448: the compliance records cover 0.17.0"
subtitle: "The gate's compliance check refuses 0.17.0 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.16.12. Both are walked against the 0.17.0 line, the first stable since 0.16.0, and stamped 0.17.0; the four register entries await the release manager."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-12
raised-by: "the compliance check, which refuses a release whose records are behind its version (SM1306 to SM1441); release manager, rulings 227 and 242"
area: release
status-note: "SHIPPED (PENDING) on n826. OBLIGATIONS.md and TECHNICAL-FILE.md at 0.17.0, channel stable; SM1444's, SM1446's and SM1447's entries and the walk's, no trigger, confirmed by the release manager on 12 Nov 2026 (ruling 251); one STRIDE row; the Declaration of Conformity restamped, unsigned; UPGRADE.md's one 0.17.0 section. Docs only."
---

# What was asked

The release gate runs the compliance check with the 0.17.0 release material written in. With
OBLIGATIONS.md `reviewed_at_version` and TECHNICAL-FILE.md `covers_version` at 0.16.12 it
refuses, as the 0.16.2 to 0.16.12 gates did. The walk reads each record against what 0.17.0
changes: the CHANGELOG's `## Unreleased` section and `git log 930e7f32a..f02c7cbb0`, 19
commits (SM1442 on n821, SM1443 on n822, SM1444 and SM1445 on n823, SM1446 on n824 and SM1447
on n825, on the 0.16.12 release commit). Rulings 227 and 242 make 0.17.0 the stable: cut with
`--final`, promoted from the 0.16.12 beta with only the fixes of the 0.16.11 and 0.16.12 field
passes. The feature freeze (ruling 228) ends with the cut.

# What it carries

- docs/SECURITY.md, a new entry dated 2026-11-12 for SM1444 (a hardening of the bad-URL
  blocker's default list, ruling 245), one for SM1447 (messages and check text; the user a
  refusal names is the owner of the store files), and the finished entry for SM1446 (a backup
  that did not finish; the detached worker, ruling 248: who runs it, how long it can run, one at
  a time, and the residual that two starts in the same instant can both pass the check). The
  walk's entry closes 0.17.0: SM1442, SM1443 and SM1445, each change's assessment, and the
  statement that 0.17.0 is the stable promotion of 0.16.12 with the field-pass fixes. None fires
  an ADR 0007 trigger. One STRIDE row, for the detached backup worker. All drafted by the developer
  agent and confirmed by the release manager on 12 Nov 2026 (ruling 251), SM1446's residual accepted
  as written.
- docs/compliance/OBLIGATIONS.md, stamped 0.17.0: the register, threat-model, SBOM, fired-trigger
  and vulnerability-handling rows; two operate-side rows (a script reading a full backup's
  answer, and a site coming from 0.16.0 reading the upgrade notes in order); the "what a person
  must confirm" section for 0.17.0. docs/compliance/TECHNICAL-FILE.md, stamped 0.17.0: the risk
  assessment current to 0.17.0, 1,824 test files. docs/POLICY.md: walked to 0.17.0.
  docs/architecture/security.md: a 0.17.0 section.
- docs/DECLARATION-OF-CONFORMITY.md: restamped to 0.17.0, unsigned, as SM1231 restamped it to
  0.16.0.
- UPGRADE.md: the 0.17.0 notes are one section in 0.16.12's shape, opening with a paragraph for
  a site coming from the 0.16.0 stable: take 0.16.1 to 0.16.12 in order, then this.

# The stable

Read from `tools/lazysite-compliance.pl`, `tools/release.sh` and docs/compliance/SIGNOFF.md.

- The two version stamps block, as on every channel, because `signoff_required` is `yes`. Done.
- The Declaration of Conformity is advisory on stable and blocks only at `certified` (ADR 0010).
  The developer restamps the unsigned draft to the stable it describes, and that is done; the
  signature and the legal review are the release manager's at the certified cut. The check still
  says "unsigned" on stable.
- The restore rehearsal is confirmed (SM1443, ruling 247) and its row is closed. The check measures
  the newest rehearsal date against the newest STABLE cut, so a cut dated after 11 Nov 2026 prints
  an advisory that the rehearsal is older; it blocks only at certified.
- A stable cut runs the coverage stage and adds the download/ commit; the release commit moves
  the 0.16 line into the changelog archive.
- The bench baseline (captured 2026-09-30) is advisory on stable and stays OPEN through the cut
  (ruling 250). It is re-captured after 0.17.0 with `perl tools/bench.pl --baseline` on a quiet
  host, at the release manager's chosen moment, before the certified cut it blocks.
- Answered by the release manager on 12 Nov 2026: the entries and the STRIDE row are confirmed (ruling
  251, SM1446's residual accepted as written); the 0.17.0 stable is not the beginning of
  general-availability marketing in ADR 0007's waiver, so the first third-party engagement stays
  due by 31 Dec 2026 (ruling 249); the bench re-capture is after 0.17.0 (ruling 250).

# Tests

None. The records are docs. The gates are the lint dir, the precheck and the compliance check run
with `--channel stable`.
