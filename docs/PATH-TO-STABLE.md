---
title: "lazysite - the path to a promotable stable"
subtitle: "One release with maximal fixes, tested in one pass, cut when the inbox has been evaluated"
brand: plain
standard-margins: true
---

# The strategy

**One release carrying as many fixes as we can land, tested in a single pass.**
When that pass produces no material findings, promote to beta - about half the
sites - and to stable after that.

The release manager cuts when the inbox has been evaluated and they have decided
what to leave. Not on a date, and not when a queue happens to look empty.

This is deliberately not optimised for cycle time. Repeated partial deployments
cost more than one considered release, in confidence as much as in effort, and
the point of a stable line is that it is trustworthy rather than recent.

# Two independent tracks

Worth stating because it is easy to assume otherwise: the report stream and the
stable gate do not block each other.

Track A - the stable gate
: records and one rehearsal, owned by the release manager, finite and not
  affected by anything in Track B. Measured 2026-08-15,
  `lazysite-compliance.pl --check --channel stable` reports 4 ok, 3 warnings,
  3 blocking, and **all three blocking items are records rather than code**.

Track B - the report stream
: engine work. It does not gate a promotion; it decides whether the promoted
  build is one worth promoting.

The build side's job is Track B, and to have Track B in a state where a single
test pass can be trusted.

# Triage, so a report does not need a conversation to be actioned

```datatable
columns: If the report is | Then
widths: 8.4cm | X
bold: 1
tone: medium
---
a silent wrong answer on a site an operator already has | fix it, completely
a documentation or observability fix that cannot change behaviour | fix it
a fix needing work in another repository | file both halves, land the one here
a question about intent, or a decision that is not the engine's | file it and ask
---
```

The first row is the one that matters. This project's recurring defect is a
control reporting success without doing the work, and every report matching that
shape earns its place.

**Complete, not partial.** A half-fix that looks whole is worse than none: it
spends the finding without closing it, and the next reader believes it is done.
Where a fix cannot be completed here - the layout catalogue is a separate
repository - both halves are written down and the filing says plainly which is
outstanding.

# The lever that reduces the stream

Fix the class, not the instance. Nearly every report across 0.10.9 and 0.10.10 is
one of three shapes:

- **surface parity** - an operation reachable on one channel and not the other
  (SM288, SM301, the MCP nav gap)
- **documented versus actual** - a description, schema default or reference table
  that disagrees with the code (ADR 0008 in SM300, `install_layout`)
- **silent success** - `ok:1`, HTTP 200, and the work not done (SM283, SM296,
  SM311, misplaced theme assets)

A lint that catches a class stops the next report in that family from being new
work. `t/lint/45`, `t/lint/46`, `t/lint/47` and `t/lint/48` were each written
that way, and each found something its own filing had not mentioned. It is the
only mechanism here that makes the next pass cheaper than this one, which is why
a fix without one is not finished.

# Sequence

1. Evaluate every inbox report and fix what triage says to fix, completely.
2. The release manager decides what is left out, and cuts.
3. One test pass against the deployed build.
4. No material findings, then promote to beta.
5. Stable after that, on Track A.

A cut made only to give the build side a checkpoint is not worth a version
number; local gate runs answer the same question without burning one.
