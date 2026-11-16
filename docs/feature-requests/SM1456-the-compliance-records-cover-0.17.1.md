---
id: SM1456
title: "SM1456: the compliance records cover 0.17.1"
subtitle: "The gate's compliance check refuses 0.17.1 with OBLIGATIONS.md and TECHNICAL-FILE.md at 0.17.0. Both are patch-walked against the diff from v0.17.0 and stamped 0.17.1; SM1455's register entry awaits the release manager."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-16
raised-by: "the compliance check, which refuses a release whose records are behind its version (SM1448)"
area: release
status-note: "SHIPPED (0.17.1): OBLIGATIONS.md and TECHNICAL-FILE.md patch-walked against the diff from 0.17.0 and stamped 0.17.1. Docs only."
---

# What was asked

`tools/gate-main.sh --version 0.17.1 --final --patch` stopped at the compliance check:
OBLIGATIONS.md `reviewed_at_version` and TECHNICAL-FILE.md `covers_version` were 0.17.0. 0.17.1
is a stable patch of 0.17.0, so the walk is a patch walk: the records are read against
`git log v0.17.0..main` and `git diff v0.17.0 main` only.

# The diff, classified

- Runtime, ships to a site: SM1455, one line in `lazysite-auth.pl` (the bad-URL guard reads
  `REQUEST_URI` behind Apache), with its tests.
- Tooling and tests, nothing a site runs: SM1454 (the patch gate, the suite-pass record, the
  register-entry confirmation, the trimmed slow tests).
- Filings and the 0.17.0 test plan: SM1449, SM1452, SM1453.

# What it carries

- OBLIGATIONS.md, stamped 0.17.1 (16 Nov 2026): the register, threat-model, technical-file,
  significant-change and vulnerability-handling rows each get their 0.17.1 note, and a short
  "Walked for 0.17.1" section. Every other row stands as walked for 0.17.0.
- TECHNICAL-FILE.md, stamped 0.17.1: the `status:` clause for the patch walk and the risk
  assessment row.
- docs/SECURITY.md already holds SM1455's entry and STRIDE row, drafted by the developer agent;
  for the release manager's confirmation. No ADR 0007 trigger fires.
- Not edited, because a patch does not touch them: UPGRADE.md, docs/POLICY.md,
  docs/architecture/security.md and the Declaration of Conformity (advisory on stable, left
  unsigned and not restamped). The bench baseline is not re-captured.

# Tests

None. The records are docs. The gates are the compliance check with `--channel stable`, the lints
that read the records or the CHANGELOG, and the precheck.
