---
id: SM1477
title: "SM1477: a site instance starts on its first request"
subtitle: "An idle site costs a resident worker and a reinstall at every container start; a pool that starts a site when it is first asked for lets thousands of sites share one host."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the SM1361 build's scale test, split out by the release manager's ruling 275"
area: performance
status-note: "CANDIDATE, filed 2026-11-17 (ruling 275). Nothing built."
---

# What was measured

The SM1361 scale test (HPS lab, 4 vCPU, 8 GiB, up to 160 sites; the table is in the SM1361
filing):

- Each idle site holds one worker: about 43 MB of memory, 5 processes, 251 inodes, 3.4 MB of disk.
  These grew in step with the number of sites.
- A container restart reinstalls each site in turn, about 5.2 s each: 827 s for 160 sites, with
  later sites answering 503 until their turn.
- Extrapolated, not measured: 2500 sites would need about 107 GB of memory, 12,500 processes and
  3.6 hours to restart.

# What is asked

A pool that starts a site's worker on the site's first request and stops it after it has been
idle, so an idle site costs disk only. A container start then has no per-site reinstall to wait
for before a site answers.

# What a build must keep true

- The first request to a stopped site is answered, late, rather than refused.
- A site's worker never serves another site's requests or reads its files.
- A test that fails against the old code: a site with no worker running answers its first request
  and has a worker afterwards; an idle site's worker is gone after the idle time.

# Questions for a ruling

1. The idle time before a worker stops, and whether a site can be held always on.
2. Whether a faster start (reinstall in parallel, or only when the engine version changed) is
   also wanted, or the pool replaces it.
