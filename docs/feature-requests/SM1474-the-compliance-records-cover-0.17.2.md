---
id: SM1474
title: "SM1474: the compliance records cover 0.17.2"
subtitle: "The gate's compliance check refuses 0.17.2 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.17.1. Both are patch-walked against the diff from v0.17.1 and stamped 0.17.2; SM1473's register entry awaits the release manager."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the compliance check, which refuses a release whose records are behind its version (SM1448)"
area: release
status-note: "OPEN. Built on branch claude/p0172-stable-patch-sm1473 (awaiting the release manager): OBLIGATIONS.md and TECHNICAL-FILE.md patch-walked against the diff from 0.17.1 and stamped 0.17.2. Docs only."
---

# What was asked

0.17.2 is an emergency stable patch of 0.17.1 (ruling 270): v0.17.1 and SM1473 only. The gate's
compliance check refuses a release whose OBLIGATIONS.md `reviewed_at_version` and
TECHNICAL-FILE.md `covers_version` are behind it, and `tools/release-material.pl` stamps a patch
only from a later release than 0.17.1, so the records are walked by hand, as SM1456 did for
0.17.1: against `git diff v0.17.1 HEAD` only.

# The diff, classified

- Runtime, ships to a site: SM1473, `lazysite-dav.pl` (a WebDAV PUT reads a page, a form config
  and a navigation file raw, and no other file), with its test t/tools/750.
- Filings: SM1473, SM1474. Nothing else from main is in the patch.

# What it carries

- OBLIGATIONS.md, stamped 0.17.2 (17 Nov 2026): the register, threat-model, technical-file,
  significant-change and vulnerability-handling rows each get their 0.17.2 note, and a short
  "Walked for 0.17.2" section. Every other row stands as walked for 0.17.1.
- TECHNICAL-FILE.md, stamped 0.17.2: the `status:` clause for the patch walk and the risk
  assessment row.
- docs/SECURITY.md holds SM1473's register entry, drafted by the developer agent; for the release
  manager's confirmation. No ADR 0007 trigger fires, and no STRIDE row is added.
- Not edited, because a patch does not touch them: UPGRADE.md, docs/POLICY.md,
  docs/architecture/security.md and the Declaration of Conformity (advisory on stable, left
  unsigned and not restamped). The bench baseline is not re-captured.

# Tests

None. The records are docs. The gates are the compliance check with `--channel stable` and the
lints that read the records or the CHANGELOG.
