---
title: "SM552: the coverage verdict block is dead under set -e"
subtitle: "A failing coverage.sh exits release.sh before COV_STATUS is read, so the release never says which coverage failure it hit or where the log is."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the tools structural review, PROVEN by probe tmp/probe-release-excerpts/result.txt part 1; class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. tools/release.sh runs under set -e (line 60), so a non-zero coverage.sh exits the script before the verdict block at 572-600 reads COV_STATUS: neither the 'below the floor' line nor the 'FAILED WITHOUT reaching the floor comparison' line ever prints, and the COV_LOG location is never shown. The probe lifts lines 60 and 572-600 with a stub coverage.sh exiting 137 and the script exits 137 with no diagnosis. t/tools/58 passes today only because its harness (64-96) omits set -e."
---

# The finding

`tools/release.sh` runs under `set -e` (`release.sh 60`). When
`coverage.sh` exits non-zero the script exits at that line, before the
verdict block at `release.sh 572-600` reads `COV_STATUS`. Neither
'below the floor' nor 'FAILED WITHOUT reaching the floor comparison'
prints, and the COV_LOG location is never shown. The probe lifts those
lines with a stub `coverage.sh` exiting 137: the script exits 137,
`VERDICT-1: diagnosis NOT printed`. `t/tools/58` passes because its
harness (58:64-96) omits `set -e`.

# Why it matters

Operability: the SM444 diagnosis exists so a release engineer can tell a
coverage floor miss from a coverage run that crashed. With the block
unreachable, every coverage failure looks the same and the log path has
to be guessed.

# The proving test

`t/tools/58-a-failed-coverage-gate-says-which-failure.t`: add `set -e`
to the generated run.sh (line 79) - fails today.

# Fix shape

`COV_STATUS=0; bash ... || COV_STATUS=$?` so the exit status is captured
rather than fatal; `t/tools/58:43` forbids the `if !` form.
