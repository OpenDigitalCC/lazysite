---
title: "SM407: the feature timeline stopped at 0.10.9"
subtitle: "FEATURES.md's newest release entry is 0.10.9 while 0.10.16 is being cut - six releases of user-facing change with no entry. The document a site owner reads to learn what the platform does is the one that fell furthest behind."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-19 by the compliance gate during the 0.10.16 edge cut, as an advisory - it does not block a cut and did not. NOT the same as the CHANGELOG being behind: the changelog is current and detailed, and every one of the six releases is fully written up there. FEATURES.md is the OTHER document - the one a site owner or a prospective operator reads to learn what the platform does - and it stopped at 0.10.9 on 2026-08-14, the point where the line accelerated to seven releases in five days. Individual features HAVE been added to it during that period (trails, the journeys panel, the registry counters, the body caps all landed with FEATURES.md edits); what is missing is the per-release framing, so the file describes a platform without saying which version any of it arrived in. SIZE: S-M, and it is writing rather than engineering. Shares a cause with [[SM408]] - both are records only a person can advance, and both stopped in the same week."
---

# What the gate found

```
WARN FEATURES.md newest release entry is 0.10.9, cutting 0.10.16
```

The check is deliberately careful: it cross-references against the CHANGELOG's
release headings rather than matching any three-part number, because FEATURES.md
also cites Perl and dependency versions and a naive match would report "current"
off a `5.40.1`.

# What is and is not behind

::: widebox
The **content** is not six releases stale. Trails, the journeys panel, the
registry counters and the request-body caps all landed with FEATURES.md edits in
the last two days. What is missing is the **release framing** - the file
describes what the platform does without saying which version any of it arrived
in.
:::

So the defect is not "undocumented features". It is that a reader cannot tell
whether the file describes the build they are running. For an operator deciding
whether to upgrade, that is the question the file exists to answer.

Six releases carry no entry: 0.10.10 through 0.10.15.

# Why it happened here

0.10.9 was cut on 2026-08-14. The line then cut **seven releases in five days**.
Per-release documentation that a person writes does not survive that cadence by
accident, and nothing failed loudly - the check is an advisory, correctly, since
a stale feature list is not a reason to refuse a build.

# Not a promotion blocker, but it is a beta one in spirit

Beta is the channel where sites that are not the operator's own start taking
builds. The feature list is what those operators read.
