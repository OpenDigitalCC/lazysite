---
title: "lazysite - non-functional review record"
subtitle: "Where the eight-dimension reviews live, and how they are named"
brand: plain
---

# Naming

**A review is keyed by the version it assesses, not the date it was written.**

```
docs/review/<version>/00-overview.md
docs/review/<version>/dimension-1-correctness.md
...
```

A review is a statement about a version: "the threat model is current" is
meaningless without saying current as of what, and two reviews can land on one
day. That happened on 2026-08-14, which is why the directories from that date
carry a version suffix and the earlier ones do not.

Existing directories keep their names - renaming them would break the
cross-references the later reviews rely on, and the record of what was assessed
when matters more than the tidiness of the folder list. New reviews use the
version.

# The record

```datatable
columns: Review | Version assessed | Verdicts
widths: 5.6cm | 3cm | X
bold: 1
tone: medium
text: 3
---
2026-06-23-seven-dimension-review.md | pre-0.7 | the first, seven dimensions
2026-07-01-eight-dimension/ | 0.6.x | first eight-dimension pass
2026-07-10-eight-dimension/ | 0.7.x | -
2026-07-18-eight-dimension/ | 0.7.28 (0.8.0 gate) | 6 PASS, 1 WARN, 1 REFUSE cleared in-cut
2026-08-14-eight-dimension/ | 0.10.8 | 1 PASS, 4 WARN, 3 REFUSE
2026-08-14-eight-dimension-0.10.9/ | 0.10.9 | 3 PASS, 4 WARN, 1 REFUSE
```

# Method

Points that earned their place across the series, recorded here so the next
assessor does not rediscover them:

- **Audit from a clean checkout of the tag**, not a working copy. A working copy
  carries untracked state that answers questions on the artefact's behalf; this
  found a defect three prior reviews had missed.
- **Measure the deployed service where one exists.** A review confined to the
  repository verifies a fix EXISTS; only a deployment verifies it WORKS.
  Confirm the deployment's version cache-independently first - a cached page
  reports the version that rendered it.
- **Verify prior findings, never assume them.** Each review re-checks the last
  one's findings as fixed or open.
- **Cite the release gate's own runs** for a tag rather than re-measuring
  coverage, which costs an hour of CPU for a number already established.
- **A projection needs an owner and a trigger per item**, or it should say
  "unscheduled". The 2026-08-14 projection missed because it counted work as
  done once it had been identified.
