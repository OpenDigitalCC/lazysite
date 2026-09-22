---
id: SM895
title: "SM895: the coverage gate reported a suite that had passed as one that did not finish, and threw away the evidence twice"
subtitle: "The first 0.14.3 cut ran the instrumented suite to a clean PASS - 932 files, 14,704 tests, 7,410 seconds - and then the report step printed nothing. coverage.sh read grep's exit as its own, release.sh read that as the suite not finishing, and removed the database the report had been built from. Two hours of measurement, no verdict, no cause."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-21
raised-by: engine agent
area: release
status-note: "SHIPPED, all three. G1 and G2 gated a real cut - 0.14.4 went through the fixed gate in one attempt, printing the footprint line and keeping cover's stderr beside the suite log (SM896 has the run). G3, the one deliberately left, is built with SM328 reconciled rather than overruled: a gate FAILURE now keeps its stage (cleanup_stage reads the exit status the trap hands it; an abort's sentence is one sentence, 'retained', and says when the directory goes), success still removes it, --keep-stage keeps a successful one too (the success path used to rm regardless, so the flag never did what its name said), and prune_dead_stages runs at the START of every run - every lazysite-release-PID directory under the stage base whose PID is not alive is removed and announced, a live PID's stage is left alone and said so, this run's own is skipped, and the PID-coverage-*.txt logs kept beside a stage survive its removal because they are the evidence (SM736b, G1). So at most one failed stage sits on the filesystem at a time, which is what SM328 needed. t/tools/87 drives the three lifted functions in a scratch base: an abort keeps and says so; success removes; --keep-stage keeps on success; a dead-PID stage is pruned by name, a live-PID one and this run's own are not, an unrelated directory is untouched, the log beside the pruned stage stays. t/tools/61's abort cases now expect retained both ways. Four sabotages (cleanup ignoring the status, prune ignoring liveness, prune removing any name, --keep-stage not keeping) each failed a test. THE TRIGGER of the original failures is SM896's, and it was inodes, not memory."
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

# The trigger, found the same evening — and it was not memory

The second attempt failed identically, kept its stage, and the operator
reported the filesystem at 0 free inodes with 4.13 million files under
`cover_db/structure`. They are hidden lock files Devel::Cover never removes,
one per structure file per process; the measurement, the probe and the
strategy are [[SM896]]. The memory candidate above is withdrawn: `cover`
printed nothing because it could not create a file. G1 and G2 are built
alongside SM896's fix; G3 is deliberately left as SM328 decided it, for the
reason recorded there.

# Related

[[SM444]] (a failed coverage gate blaming coverage — the same family, one layer
out), [[SM552]] (the exit-status capture that let release.sh reach its verdict
block at all), [[SM736b]] (the coverage record that has to be carried back out
of the stage — the same "the stage is deleted" shape, for the success path).
