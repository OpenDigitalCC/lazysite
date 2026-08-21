---
title: "SM444: a failed coverage gate reports a floor breach whichever way it failed"
subtitle: "release.sh treats ANY non-zero exit from coverage.sh as 'coverage below the declared floor'. The 0.10.20 build failed that way and coverage was never the problem - it cost a 45-minute instrumented re-run and a second full build to establish that."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-21 after it misdirected an actual release. The 0.10.20 build stopped with 'release.sh: coverage below the declared floor; not releasing.' The obvious reading - the afternoon's new code is under-covered - is what I acted on, and it was wrong. THE EVIDENCE IS AN ABSENCE, and it is decisive: coverage.sh --check prints a per-file table (`stmt NN% bran NN% (floors ...) ok|BELOW|BELOW-BRANCH`) for EVERY measured file BEFORE it decides, and prints 'COVERAGE BELOW FLOOR' to stderr when a floor is actually missed. release.sh invokes it with no redirection, so both would have appeared in the release log. NEITHER DID. The log goes straight from 'Running the suite under Devel::Cover, 4-way' to release.sh's own message. So coverage.sh never reached the floor comparison; it exited non-zero earlier, and release.sh asserted a cause it had not established. WHAT IT ACTUALLY COST: a standalone 45-minute instrumented run to get the numbers, which passed on every file - and then a full second release build, which also passed, with branch coverage differing from the standalone run by at most 0.3 points on the same commit. Three measurements agree; there was never a coverage shortfall to find. THE MECHANISM IS ONE LINE: `if ! bash \"$STAGE/tools/coverage.sh\" --check; then echo 'coverage below the declared floor'`. Every failure mode of a 15-minute instrumented run - a worker killed, Devel::Cover missing, the staging disk full, the run crashing - arrives at the same sentence. LEADING CANDIDATE FOR THE REAL CAUSE, NOT ESTABLISHED: the box was under severe memory pressure that night - 12 Claude sessions holding 5.7GB of 9.7GB with swap fully exhausted, and available memory measured as low as 267MB during a later instrumented run. An OOM-killed Devel::Cover worker would produce exactly this: a non-zero exit with no table. That build's processes carried no oom_score_adj protection, so the kernel chose freely. I cannot prove it after the fact BECAUSE THE LOG DOES NOT SAY, which is the filing. THIRD OF A CLASS TODAY: SM436's domain check said 'add the DNS record' when the DNS was fine, SM442's regenerate reported cleared_roots that could not distinguish four files from none, and this asserts a floor breach it never measured. Each is accurate about internal state and misleading about what the operator should change."
---

# The evidence is what is missing

`coverage.sh --check` prints, per file, before deciding:

```
  lazysite-dav.pl    stmt  93.3%  bran  73.9%  (floors 75%/62%)  ok
```

and, when a floor is genuinely missed, `COVERAGE BELOW FLOOR` on stderr.

The failed 0.10.20 log, in full, at that point:

```
==> coverage.sh --check (instrumented run; ~10-15 minutes)
Running the suite under Devel::Cover, 4-way (subprocess CGIs instrumented)...
release.sh: coverage below the declared floor; not releasing.
```

::: widebox
No table. No `COVERAGE BELOW FLOOR`. `release.sh` does not redirect the child,
so both would have been in the log had they been produced. **The floor
comparison was never reached** - and the message naming it as the cause was
written before anyone knew that.
:::

# What it cost

```datatable
columns: Step | Outcome
widths: 7cm | X
bold: 1
tone: medium
---
Read the message, act on it | investigate the afternoon's new code for coverage gaps
Standalone instrumented run | 45 minutes - **every file passes**
Second full release build | 1h22m - **passes again**, branch figures within 0.3 points
```

Three measurements of one commit agree. There was no coverage shortfall to
find, and two runs were spent proving a negative that the first log could have
ruled out in a line.

# The mechanism

```perl
if ! bash "$STAGE/tools/coverage.sh" --check; then
    echo "release.sh: coverage below the declared floor; not releasing." >&2
```

Every way a 15-minute instrumented run can fail - a worker killed, the
staging disk filling, `Devel::Cover` absent, the run crashing - arrives at that
one sentence.

# The likely real cause, and why it cannot be confirmed

That night the machine held **12 Claude sessions using 5.7GB of 9.7GB with
swap fully exhausted**; a later instrumented run was measured dipping to 267MB
available. An OOM-killed `Devel::Cover` worker produces exactly what was seen:
a non-zero exit, no table. That build's processes carried no `oom_score_adj`
adjustment, so the kernel chose freely between them and everything else.

**Not established** - and it cannot now be, because the log does not say. That
is the filing, not an aside.

# Remedy

1. **Do not name a cause the gate has not measured.** `coverage gate FAILED
   (exit N)` is honest and no less useful.
2. **Distinguish the two cases.** `coverage.sh` already signals a real floor
   breach with `COVERAGE BELOW FLOOR`; keying on that separates "below floor"
   from "did not finish".
3. **Keep the table.** Capture the child's output and echo it on failure, so a
   real breach names the file and the margin in the release log rather than in
   a re-run.

Cheap, and each of the three is independently worth having.

# The class

```datatable
columns: Filing | Says | Actually
widths: 3cm | 6cm | X
bold: 1
tone: medium
---
SM436 | "add the DNS record" | the DNS was fine; the registered name was not a hostname
SM442 | `cleared_roots: [...]` | the roots considered - could not distinguish four files from none
SM444 | "coverage below the declared floor" | the floor was never evaluated
```

Each is accurate about some internal state and misleading about what the
operator should change. Worth reading together when any of them is fixed.
