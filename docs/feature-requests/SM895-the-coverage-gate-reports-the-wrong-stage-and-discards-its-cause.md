---
id: SM895
title: "SM895: the coverage gate reported a suite that had passed as one that did not finish, and threw away the evidence twice"
subtitle: "The first 0.14.3 cut ran the instrumented suite to a clean PASS - 932 files, 14,704 tests, 7,410 seconds - and then the report step printed nothing. coverage.sh read grep's exit as its own, release.sh read that as the suite not finishing, and removed the database the report had been built from. Two hours of measurement, no verdict, no cause."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-21
raised-by: engine agent
area: release
status-note: "FILED from the first 0.14.3 cut, 2026-09-21 - the cut that produced it was relaunched with --keep-stage and is running as this is written; whether the report step fails again is what settles the cause, and this filing does not guess at it. WHAT IS ESTABLISHED, from the logs and the code: the instrumented suite PASSED (coverage-suite.txt: 'All tests successful. Files=932, Tests=14704, 7410 wallclock secs'); coverage.sh then ran `cover -silent -report text \"$DB\" 2>/dev/null | grep -vE '^Run:'` under `set -e` with no pipefail, so the pipeline's status is grep's, and grep -v of EMPTY input exits 1; the script died there, before the floor comparison; release.sh printed 'The instrumented run did not finish' - which is false, it finished and passed - and then rm -rf'd the staging clone, cover_db inside it. `cover` produced no output over twelve minutes and its stderr went to /dev/null. So the one process that failed is the one process whose words nobody kept. NOT CLAIMED: why cover printed nothing. Memory is the obvious candidate (the host was under enough pressure at that moment for the session harness to kill an unrelated 15-second poll loop) and there is no kernel OOM line readable for the window, so it stays a candidate. Three separable faults: G1 the report step hides its own stderr; G2 the verdict names the wrong stage; G3 a failed gate deletes the database that would let anyone find out why. --keep-stage exists and is opt-in, which is the wrong default for a FAILURE."
---

# What happened, in order

The first cut of 0.14.3, launched 12:35 BST, `release.sh build 0.14.3 --final
--no-fetch --commit main --stage-dir /srv/projects/lazysite/tmp/stage`:

| Time | Stage | Outcome |
| --- | --- | --- |
| 12:35 | plain suite in the staging clone | passed |
| ~12:50 | perf baseline | 6 timings, 6 work counters checked |
| 12:51 → 14:54 | instrumented suite (Devel::Cover, 4-way) | **PASS — Files=932, Tests=14704, 7410 wallclock secs** |
| 14:54 → 15:06 | `cover -silent -report text "$DB" 2>/dev/null` | **printed nothing** |
| 15:06 | coverage.sh | exited 1, before the floor comparison |
| 15:06 | release.sh | *"coverage gate FAILED (exit 1) WITHOUT reaching the floor comparison - so this is NOT a coverage shortfall. The instrumented run did not finish."* Staging dir removed. No tag. |

The suite log kept outside the stage (`lazysite-release-157563-coverage-suite.txt`,
299 KB) ends:

```text
All tests successful.
Files=932, Tests=14704, 7410 wallclock secs ( 7.17 usr  1.98 sys + 16146.46 cusr 7855.54 csys = 24011.15 CPU)
Result: PASS
```

The coverage-check log kept outside the stage is two lines long:

```text
Running the suite under Devel::Cover, 4-way (subprocess CGIs instrumented)...
suite under instrumentation: exit=0, 932 file(s) reported
```

# The mechanism, read from the code

`tools/coverage.sh` line 16: `set -e`. No `pipefail` anywhere in the file.
Line 260, immediately after the "reported" echo:

```bash
cover -silent -report text "$DB" 2>/dev/null | grep -vE '^Run:[[:space:]]'
```

Under `set -e` without `pipefail` the status of a pipeline is the status of
its **last** command. `grep -v` exits 1 when it selects no lines — which is
what it does when its input is empty. So `cover` producing no output is
indistinguishable, to this script, from `cover` producing only `Run:` lines,
and both end the script at line 260 with exit 1.

`tools/release.sh` lines 668–682 catch that status, look for `COVERAGE BELOW
FLOOR` in the log, do not find it, and print the "did not finish" message.
Line 347: `cleanup_stage() { [ "$KEEP_STAGE" = 1 ] || rm -rf "$STAGE"; }` —
the database `cover` had just failed to report on is deleted with the clone.

# Three faults, and they want different fixes

| Ref | Fault | What would close it |
| --- | --- | --- |
| G1 | **The report step hides its own stderr.** `2>/dev/null` on the one command that turned two hours of measurement into a verdict. Whatever `cover` said as it died — out of memory, a corrupt run file, a DB it could not open — is gone. | Capture `cover`'s stderr to the COV_LOG (which release.sh already keeps outside the stage), and capture the pipeline's own status with `pipefail` or by running `cover` into a file first and testing the file. |
| G2 | **The verdict names the wrong stage.** "The instrumented run did not finish" is false: it finished, passed, and said so in the line above. release.sh infers the stage from the absence of one string in the log rather than from what coverage.sh reports. | coverage.sh already distinguishes "suite failed" (exit 3, with its own message) from everything else. Give the report step its own exit code and message — *"the suite passed; the coverage REPORT failed: <cover's stderr>"* — and have release.sh print that rather than a guess. |
| G3 | **A failed gate deletes the evidence.** `--keep-stage` is opt-in. A gate FAILURE is exactly when somebody wants the stage, and the comment at line 344 says so; the default is still to remove it. | Keep the stage on any non-zero exit, remove it on success. `--keep-stage` then means "even on success". |

G1 is the one that matters. G2 and G3 made the first failure expensive; G1 made
it uninformative, and an uninformative failure of a two-hour gate is the one
that gets re-run blind — which is what happened.

# What is NOT claimed

- **Why `cover` printed nothing.** Memory is the candidate: the report step
  loads and merges a 4-way, 932-file `cover_db`, the host was under enough
  pressure at that moment for the session harness to kill an unrelated
  15-second poll loop, and the instrumented suite itself took twice the
  script's own estimate. But `journalctl -k` and `dmesg` are readable here and
  show no OOM line for the window, and the process's own words were discarded.
  A candidate, recorded as one.
- **That it will recur.** The relaunch with `--keep-stage` is the reproduction
  attempt. If the report step fails again, the DB is on disk and `cover` can be
  run by hand with stderr visible. If it passes, this stands as one occurrence
  with the mechanism established and the trigger not.
- **Any coverage shortfall.** No number was produced. The floors were never
  compared.

# Related

[[SM444]] (a failed coverage gate blaming coverage — the same family, one layer
out), [[SM552]] (the exit-status capture that let release.sh reach its verdict
block at all), [[SM736b]] (the coverage record that has to be carried back out
of the stage — the same "the stage is deleted" shape, for the success path).
