---
title: "SM629: a content-history row said when, who and what, and not how much"
subtitle: "Operator: 'on files history, add file / diff size in the row'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED in 0.11.2 (edge, 2026-08-26). FILED RETROSPECTIVELY during the 0.11.2 filing sweep, which found this ref in the changelog with no filing behind it. Judging which revision to open meant opening several. Lines added and removed answer 'which one was the big edit' at a glance, and come from --numstat on the git log call the timeline ALREADY makes - no extra process per revision. TWO THINGS THAT ARE NOT COSMETIC. A binary file reports '-' for both counts: that arrives as undef and renders as 'binary', never as '+0 -0', because 'nothing changed' and 'not countable in lines' are different answers and 0 states the wrong one confidently. And the numstat line arrives AFTER its commit line, so the lineage walk defers its stop by one record - stopping on the commit line, which is the obvious way to write it, leaves the LAST row of every page with no size, and that is the row a reader most often wants (the oldest shown, where a file was created). DELIBERATELY OUT OF SCOPE: the file's SIZE IN BYTES at each revision. run_git is output-only, so per-revision bytes would need a `git cat-file --batch-check` fed on stdin - a new helper. Lines added and removed is the number a history row wants; bytes can follow if anyone asks. A sabotage found the binary path untested in the module: the render half covered it and the parser half did not, so counting '-' as 0 passed."
---

# What the row says now

| When | Who | Change | **Size** |
|---|---|---|---|
| … | … | grow a | **+12 −3** |
| … | … | add an image | **binary** |
