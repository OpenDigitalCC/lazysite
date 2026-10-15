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

# Coverage in parts

The release manager, 2026-10-15: "no need to run every night if the code
hasnt changed. i dispefer the overnight anyway - so having cover run on
demand is preferred. maybe it can be broken down into smaller parts, as i am
sure it all isnt needed for every change."

Shipped on n590 (PENDING). The measured files fall into nine groups, read from
the area map (tools/precheck-areas.pl): processor, manager, auth, data, front,
daemon, odoo, lib, tools. tools/coverage-groups.pl is the one declared place.
Each group has

- its own inputs digest: its code files, the tests the area map selects for
  its prefixes, its floor lines and the coverage scripts;
- its own cover DB (cover_db-GROUP) and suite log;
- its own recorded pass, tmp/release-gate/coverage-passes/GROUP/DIGEST.json;
- its own floor lines, dist/config/coverage-floor-groups, inheriting the
  general floor= and branch_floor= from coverage-floor.

`tools/coverage.sh --check` hands over to tools/coverage-parts.sh: behind the
preflight and the heavy lock it measures only the groups whose digest has no
recorded pass, reuses the rest, and stops - naming the group - when one cannot
be matched. `--all` measures every group; `--groups` lists each group's state
and runs nothing. The gate asks for the groups' combined digest and releases
only when every group matched or measured. A group with no floor-checked file
(data, daemon, odoo, lib) has nothing to measure and is marked so.

A reused pass says less than it did: a change to a shared module re-stales
the `lib` group, not every group that calls it. That is the trade the ruling
asks for and the filing says so.

## The one-time re-baseline

The floors were measured under the whole suite, where a file is also reached
by tests of other areas; a group measured alone can come in lower with no
code having got worse. Every group starts `status=pre-rebaseline`: a file
under its starting floor is reported as MOVEMENT, kept in the group's record,
and does not fail. The re-baseline run is `LAZYSITE_COVER_FORCE=1
tools/coverage.sh --check --all` on the host when the preflight allows it
(MemAvailable 6 GB or more, swap under 1 GB, nothing else heavy); it reads
each group's movement line, writes the measured numbers into
coverage-floor-groups beside the whole-suite values for comparison, removes
the status lines, and lands as one deliberate commit. Until then a per-group
shortfall is reported, not enforced. Ratchet upward after that - never down.
