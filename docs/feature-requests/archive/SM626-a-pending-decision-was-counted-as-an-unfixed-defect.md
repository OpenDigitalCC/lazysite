---
title: "SM626: a fleet of 26 healthy sites reported as 26 needing a human, because a pending decision was counted as an unfixed defect"
subtitle: "From the 0.11.1 fleet repair. Every site: 43 ok, 0 failures. Summary: '0 clean, 0 repaired, 26 need a human'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (edge, 2026-08-26), alongside SM625 and SM627 and originally documented with them; filed separately so the ref can be cited on its own. `repair` bucketed by grepping for [ warn ] OR [ FAIL ] and treating both the same. The only outstanding item across the fleet was a WARNING that a group seeded before this release has not been told what to do about the capabilities the release added - which CANNOT be repaired: it clears when a human decides. So every healthy site sat in the worst bucket, the tally could never improve no matter how many repairs ran, and the run exited NON-ZERO - meaning a scheduled fleet check goes red permanently and stops being read, which is the failure mode a check exists to avoid. Split into 'awaiting your decision' and 'need a human', separated by the doctor's own [ FAIL ] marker rather than by matching the capability sentence, which would rot the next time that wording changes. Exit status follows FAILURES only: a standing decision is not an incident."
---

# What it said, and what was true

| Reported | Actual |
|---|---|
| `0 clean, 0 repaired, 26 need a human` | 26 sites, 43 ok, **0 failures** each |
