---
title: "SM601: `bench.pl --baseline` has been dead since 2026-08-15, and each attempt destroyed the baseline"
subtitle: "The encode writes a loadavg field whose function was never defined, so the mode died at the point of writing - after `open '>'` had already truncated the file it was replacing."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-26 during the 0.11.0 stable prep, the first time anything re-captured the baseline since the field was added. `--baseline` calls `_loadavg()` in the hash it encodes; there is no `sub _loadavg`. The mode therefore died every time it ran - `Undefined subroutine &main::_loadavg at tools/bench.pl line 277` - and it has done so since 2026-08-15, eleven days, unnoticed because RE-CAPTURING IS THE ONLY THING THAT CALLS IT and nothing re-captured. THE SECOND HALF IS WORSE THAN THE FIRST. `open my $b, '>', $BASELINE` truncates before the encode is evaluated, so each failed attempt left a ZERO-BYTE baseline behind: a failed capture destroyed the reference it existed to replace. Inside a git checkout that is one `git checkout` away. On a CI or deploy host - which is exactly where the file's own header says to re-capture - it is simply gone, and the next `--check` has nothing to compare against. FIXED BOTH WAYS: `_loadavg` reads /proc/loadavg and returns the three figures or undef; the write goes to a temp file and is renamed into place, so a die mid-encode cannot touch the baseline. Sabotage-verified in both directions. WHAT THE FIELD IS FOR, and why its absence mattered rather than being cosmetic: the comment beside it says a run on a loaded host and a genuinely slower engine look identical in the numbers. The 0.11.0 capture records loadavg [0.61, 1.01, 0.79], which is what makes it interpretable later. WHY NOTHING CAUGHT IT: there was no test for tools/bench.pl at all. t/tools/65 now pins the two properties that rotted - every helper the encode calls exists, and the writer does not open the baseline itself - without running the benchmark, which takes minutes."
---

# What happened when it ran

```
$ perl tools/bench.pl --baseline
Undefined subroutine &main::_loadavg called at tools/bench.pl line 277.
$ stat -c%s dist/config/bench-baseline.json
0
```

# The two defects

| | Defect | Effect |
|---|---|---|
| 1 | `_loadavg()` called, never defined | `--baseline` cannot capture at all |
| 2 | `open '>'` on the baseline itself | a failed capture truncates it to zero |

The second is the one that matters away from a git checkout. The header
of this very file says to re-capture **on your CI/deploy host** - the one
place where a destroyed baseline is not one command away from coming back.

# Why eleven days

Re-capturing is the only caller. `--check` reads the baseline and never
writes one, and `--check` is what the release runs. So the mode that
maintains the reference was exercised by nothing, and the gate that
depends on the reference could not tell.
