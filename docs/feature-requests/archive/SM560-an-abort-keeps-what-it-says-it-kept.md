---
title: "SM560: an abort keeps what it says it kept"
subtitle: "release.sh prints staging dir retained on thirteen abort paths and the EXIT trap then removes the directory, so the path an engineer is told to inspect is gone."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): release.sh's eleven abort paths now call one stage_disposition helper that prints 'retained: PATH' under --keep-stage and 'removed (re-run with --keep-stage to inspect): PATH' otherwise, so the sentence matches the SM328 trap; the header and SM444 comment say the same. Proving test t/tools/61-an-abort-keeps-what-it-says-it-kept.t lifts the helper and trap, aborts both ways, and requires the printed path to exist or the line to say it was removed and how to keep it; it found no helper before the fix. FOUND 2026-08-25 by the tools structural review, PROVEN by probe tmp/probe-release-retained/result.txt; class: operability; recommended timing: later. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. tools/release.sh prints 'staging dir retained: $STAGE' on thirteen abort paths, and the EXIT trap at 343 removes the directory unless --keep-stage was given; the header (57-59) and the SM444 comment (570-571) both promise retention. The probe runs a real build 9.9.9 with perlcritic off PATH: line 8 prints the path, the directory is gone at exit, exit 1, no tag created."
---

# The finding

`tools/release.sh` prints `staging dir retained: $STAGE` on thirteen
abort paths, and the EXIT trap (`release.sh 343`) removes the directory
unless `--keep-stage` was given. The header (`release.sh 57-59`) and
the SM444 comment (`release.sh 570-571`) both promise retention. The
probe runs a real `build 9.9.9` with perlcritic off PATH: line 8 of the
output prints the path, `VERDICT: NOT retained`, exit 1, no tag
created.

# Why it matters

Operability: an aborted release tells the engineer where to look and
that place has already been deleted, so the first diagnostic step after
every gate failure is a dead end.

# The proving test

NEW `t/tools/61-an-abort-keeps-what-it-says-it-kept.t`: one assertion -
the printed path exists, or the line says 'removed (re-run with
--keep-stage)'.

# Fix shape

Either keep the stage on abort as the message and header promise, or
change the thirteen messages to say the directory was removed and how
to keep it; review item TO-28 folds the thirteen blocks into one
`abort_build`, which is where the single wording would live.
