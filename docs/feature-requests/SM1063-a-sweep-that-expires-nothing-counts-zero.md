---
id: SM1063
title: "SM1063: a sweep that expires nothing counts zero"
subtitle: "The connector sweep declared its counters after an array in one list assignment, so the array took the zeros: the counts were null and the kept list began with two stray values."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 follow-up
area: connectors
status-note: "SHIPPED (PENDING): Connectors::sweep declares its counters before the kept list; t/lint/257 refuses a scalar after an array or hash in a my/our/state list with an assignment. t/unit/manager/335, t/lint/257."
---

# What was wrong

`Lazysite::Manager::Connectors::sweep` opened with

    my ( @keep, $expired, $unanswered ) = ( (), 0, 0 );

A list assignment gives an array every value left on the right. `@keep` took
`(0, 0)` and both counters started undef. Two results:

- A sweep with nothing to expire returned `expired => undef`, and one with no
  stuck calls `unanswered => undef`. The daemon's `connectors-sweep` job
  (`Lazysite::Daemon::Jobs::connectors_sweep`) passes both into its run record,
  which said `null` where the count was 0.
- `kept` was two more than the records kept. A sweep that expired anything
  rewrote the call record from `@keep`, so it wrote `00` in front of the first
  kept line. That line no longer decoded as JSON, and every later read of the
  record (the listing, the next sweep) skipped it: one call record lost per
  sweep that expired something.

# The fix

    my ( $expired, $unanswered, @keep ) = ( 0, 0 );

`lib/Lazysite/Manager/Connectors.pm:960`.

# The same shape elsewhere

A scan of `lib/`, `tools/`, `plugins/`, `lazysite-processor/`, the top-level
`*.pl` and `t/` for a declaration list with an assignment in which an array or
hash is not last:

| Ref | Where | Shape | Verdict |
|---|---|---|---|
| H-1 | `lib/Lazysite/Manager/Connectors.pm:960` | `my ( @keep, $expired, $unanswered ) = ( (), 0, 0 )` | the bug; fixed |
| H-2 | `lazysite-mcp.pl:2972` | a comment quoting SM260's `my ( @stale, @stack ) = ( (), $DOCROOT )` | the earlier instance, already fixed |
| H-3 | 23 test files, `local ( @ARGV, $/ ) = $file` | slurp idiom | intended: the undef `$/` is the point |
| H-4 | `t/lint/109:61`, `t/lint/137:119`, `t/lint/199:51`, `t/lint/244:22` | a scalar, then only arrays or hashes | correct: the scalar is first and the aggregates are meant empty |

No other code instance.

# The lint

`t/lint/257-an-array-in-a-declaration-list-comes-last.t` refuses a scalar
after an array or hash in a `my`, `our` or `state` list with an assignment,
across the trees above. `local` is not checked (H-3), nor a line where the
shape follows a `#`. It checks its own pattern against the bug's line, a hash
across lines, `our`, and the fine shapes (scalars first, scalar then
aggregates, the slurp idiom, a declaration with no assignment, a comment). No
false positive on the current tree.

# Tests

- t/unit/manager/335: a sweep that expires nothing reports 0 and 0 and no
  `null`; an expiry with nothing stuck says 0 unanswered; a stuck call with
  nothing expired says 0 expired; a sweep that expires one record leaves the
  other as the one readable line in the file.

335 fails on n550 (all four subtests). Sabotaged by restoring the old line
(tmp/sab-n553.sh, backup in tmp/sab-bak/n553/, restored by cp, cmp clean):
335 fails all four subtests and lint 257 names `Connectors.pm:960`.

# Related

[[SM260]], [[SM579]], [[SM666]].
