---
id: SM1083
title: "SM1083: a reliable release gate that guards itself"
subtitle: "A heavy job refuses to start where it cannot finish, one lock keeps heavy jobs apart, the stage is on disk, and a failure costs the reader twenty lines."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-15
raised-by: release manager, 2026-10-15
area: release
status-note: "SHIPPED (PENDING) on n589: tools/preflight.sh, tools/heavy-lock.sh, tools/stage-default.sh, tools/failure-digest.pl; gate-main.sh, coverage.sh, suite.sh, overnight.sh wired. Coverage in parts is filed as n590 (see the plan row)."
---

# What happened

A release gate that takes three to five hours and fails has cost a week. Since
2026-10-12 it failed for five different reasons: the filings lint, the
mapper-spec lint (three times), two memory kills, and t/tools/104 under
Devel::Cover. On 2026-10-15 the coverage stage ran 5.2 hours at two jobs;
t/tools/104 failed because its nested release.sh refuses a stage base with
under 500,000 free inodes (/tmp is a RAM-backed tmpfs and the gate's own stage
plus the Devel::Cover DB left 431,000) and because Devel::Cover prints
"Deleting old coverage for changed file ..." to stderr where the test expects
nothing; then `cover` merged 16,380 runs, used all memory and was killed
(exit 143).

# The ruling

The release manager, 2026-10-15: "i dont want this release to be special, i
want a process that is reliable ... a more intelligent way of running the
tests that is less wasteful". Later the same day: "no need to run every night
if the code hasnt changed ... having cover run on demand is preferred ...
maybe it can be broken down into smaller parts, as i am sure it all isnt
needed for every change." No waiver and no special case for any release.

# What shipped

- `tools/preflight.sh HEAVY` refuses to start a heavy job unless MemAvailable
  is at least 6 GB, swap in use at most 1 GB, the stage base has 3 GB and
  600,000 inodes free and no other heavy job holds the lock. Exit 3 means
  "not now": a SKIP for the caller, never a failure.
- One heavy lock (`tools/heavy-lock.sh`, under the git common dir) is taken
  by the gate, coverage.sh run alone and suite.sh; a waiter names the holder.
- The gate's stage defaults to /var/tmp/lazysite-stage; retained stages older
  than 2 days are removed at the next run.
- Coverage jobs default to 4 when MemAvailable is at least 8 GB, else 2. A
  killed `cover` (137/143) is the verdict "KILLED (memory/signal)".
- t/tools/104 stages on disk when /tmp is a tmpfs and ignores `Devel::Cover:`
  lines.
- `tools/failure-digest.pl LOG` prints at most 20 lines with a class (ENV or
  TEST); used in the nightly inbox note and the gate's failure message.
- tools/overnight.sh does no work when main is the commit the last green night
  tested and the queue is empty. Coverage is not scheduled: it runs on demand.
