---
title: "SM280 - Progressive coverage: the only remaining way to move the 80-minute gate"
subtitle: "SM269 phases 0-2 measured the hour and improved the developer loop without touching the release gate. Coverage is 92% of it, and phase 3 is the only lever left."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18 by sharding, which is the one candidate that keeps the gate's MEANING intact - deferring to a schedule and covering a rotating slice both trade coverage of this commit for speed. It needed no merging machinery: Devel::Cover already writes a directory per process under the shared db and `cover` merges them, the same mechanism that lets instrumented CGI subprocesses be counted at all, so parallel prove workers are more of the same writers. MEASURED BEFORE CHANGING ANYTHING, on t/unit/mcp: serial 467s at 52.2% statement / 27.2% branch, -j4 182s at 52.2% / 27.2%. 2.6x faster with the numbers identical to the decimal - and the identical numbers are the half that matters, because a faster run reporting DIFFERENT coverage would be a faster run measuring something else. Job count capped at 4 with an override rather than derived from nproc: the run is inode-heavy, a directory per instrumented subprocess, and release.sh already refuses to stage where inodes are short. Extrapolating the slice to the whole gate suggests roughly 80 minutes to the mid-30s, but that is an estimate from one slice and is not claimed as measured. SPLIT from SM269 on 2026-08-11, which is now closed as shipped for phases 0-2. Carries phase 3 and nothing else. NOT STARTED. Sized L, and the filing itself says the most likely outcome is a scheduled job nobody reads - that finding would be a result, not a failure, and SM269's brief said so first."
---

# SM280 - progressive coverage

## What SM269 established, so this does not re-measure it

Phase 0 attributed the hour with `strace`, not estimation:

- **coverage is 92% of gate wall-clock**, at a 12.4x instrumentation multiplier;
- the top 20 files are half the plain suite;
- 57-65% of the spawn-heavy tests is perl compiling the same five CGIs.

Phase 1 sharded the perlcritic sweeps and gave the shared repo-root manifest one
owner instead of six copies of its lifecycle: `prove -j4` is green at 122s
against 330s. Phase 2 put a tier ladder in the Makefile.

Both improved the **developer loop**. Neither moved the **release gate**, and
SM269 recorded that plainly rather than claiming a win.

One negative finding is worth carrying forward so nobody spends a day
rediscovering it: **preload cannot touch the compile tax.** It is paid in CGI
subprocesses the tests spawn themselves, and no harness can preload a child it
does not control. Like-for-like, `yath` is 126s against `prove -j4` at 122s.

## What is left

Coverage is the gate. Anything that does not reduce, defer or parallelise the
coverage run does not change the 80 minutes.

The candidate shapes, in the order I would try them:

1. **Shard the coverage run.** `Devel::Cover` supports merging databases from
   separate runs. If N forks each cover a slice and the databases merge, the
   wall-clock divides by roughly N while the report stays whole. This is the
   only option that keeps the gate's meaning intact, so it goes first.
2. **Defer coverage off the gate and onto a schedule**, with the gate keeping
   the plain suite. Cheap, and the reason phase 2 deliberately shipped **no**
   scheduled tier: a scheduled job has to justify itself before it exists.
3. **Cover a slice per run**, rotating, so every file is covered within a few
   releases rather than every release. Weakest, and the easiest to fool
   yourself with.

## The risk this filing already knows about

**A scheduled coverage report that nobody reads is worse than an 80-minute gate**,
because the gate is at least felt. SM269's brief said so before any of this was
built, and it remains the thing most likely to happen.

So option 2 needs a stated answer to "who reads it, and what happens when it goes
red" BEFORE it is built, not after. If that answer is not convincing, option 1
or nothing.

## Acceptance

Either the gate's wall-clock falls materially with the coverage report intact,
or this filing closes with a recorded finding that it cannot without weakening
the gate - and 80 minutes is the honest price of the assurance. The second is a
legitimate outcome.

## Related

[[SM269]] (phases 0-2, closed), and the release-gate timing notes in
`DEVELOPER.md`.
