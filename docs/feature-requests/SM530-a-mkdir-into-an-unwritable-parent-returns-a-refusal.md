---
title: "SM530: a mkdir into an unwritable parent returns a refusal"
subtitle: "The manager's own mkdir dies instead of refusing, so the caller sees a tool error and the audit log records nothing."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the path-core structural review, PROVEN by probe tmp/pathcore-probe.t (P4, evidence in tmp/pathcore-probe.out); class: operability; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. With an unwritable parent, make_path($full) or return {...} at Manager/Files.pm 850 never reaches the or: File::Path::make_path croaks, the CGI dies with mkdir: Permission denied, the caller sees a tool error and no audit line is written. This is the SM296 lesson recorded in Private.pm 207-222, repeated on the manager's own mkdir. The same unguarded make_path sits at 411, 523, 896 and 985. Fix: make_path with error => \\$err and a real refusal, with Private::_mkpath as the pattern."
---

# The finding

With an unwritable parent, `make_path($full) or return {...}`
(`Manager/Files.pm 850`) never reaches the `or`: `File::Path::make_path`
croaks. The CGI dies with "mkdir ...: Permission denied", the caller
sees a tool error and no audit line is written. This is the SM296 lesson
recorded in `Private.pm 207-222`, on the manager's own mkdir. The same
`make_path($dir) unless -d $dir` guards sit at `Manager/Files.pm 411,
523, 896, 985`.

# Why it matters

Operability: a refusal tells the operator what was refused and why, and
leaves an audit line; a die leaves a bare server error and an audit gap
exactly where a permissions problem needs diagnosing.

# The proving test

A NEW `t/unit/manager/` test: "a mkdir into an unwritable parent returns
a refusal".

# Fix shape

Call `make_path` with `error => \$err` and return a real refusal hash on
failure; `Private::_mkpath` is the pattern. Apply the same guard at the
four other sites.
