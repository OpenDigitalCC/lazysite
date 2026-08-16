---
title: "SM340 - the first-party export cache is written every run and never read"
subtitle: "The loader accepts version 1. The first-party path writes version 2. So the default statistics path discards its cache on every call, re-reads every retained log, and rebuilds every day bucket from scratch - and its per-file byte offsets, the entire point of the incremental design, have never once been used."
brand: plain
status: candidate
status-note: "FILED 2026-08-16, found while measuring [[SM338]]'s behaviour for a partner agent and NOT fixed in 0.10.12. Verified by sabotage rather than by reading: after a run, the stored per-file offsets were set past the end of the log, and the next run returned identical counts - a cache that was being honoured would have skipped everything. This is pre-existing and independent of SM329/SM338, which merely made it visible. It is NOT fixed here because making the cache load for the first time is a large behavioural change - offsets honoured, buckets persisted, days retained beyond their logs - and that belongs in a release where it is the thing being tested, not one already through suite and bench. It does mean SM338's historical-basis claim is false on the default path, and that filing has been corrected rather than left standing."
---

# What was found

```perl
# the only loader, at the single call site
return ( ref $c eq 'HASH' && ( $c->{v} // 0 ) == 1 ) ? $c : undef;
```

```perl
# what the first-party ingester writes
%{$cache} = ( v => 2, files => {}, days => {}, events => [] );
```

The loader accepts version 1. The first-party path writes version 2. So the
load returns `undef`, `|| {}` supplies an empty hash, and the ingester's own
guard then reinitialises it - every single call.

`first_party` **defaults to true**, so this is the path essentially every site
is on. The server-log path writes version 1 and its cache does load, which is
why the behaviour looks correct whenever it is exercised without first-party
logs present - including in the fixture that first measured SM338.

# How it was verified

Not by reading the version numbers, which is how it stayed unnoticed. After a
normal run the stored per-file offsets were rewritten to a value past the end of
the log:

```datatable
columns: | human_visits | events
widths: 8cm | 3.4cm | X
bold: 1
tone: medium
---
run 1 | 5 | 5
offsets set to 99,999,999 | - | -
run 2 | 5 | 5
---
```

A cache that was being honoured would have skipped the entire log and returned
zero. The numbers did not move, because nothing read them.

# What it costs

Every export re-reads every retained log
: the incremental design is the whole reason for per-file offsets, and it has
  never been in effect. Cost grows with `retention_days`, default 90.

A day whose log has rolled off disappears from the index
: its bucket cannot be rebuilt, and nothing reads day files back in. The durable
  day file remains on disk, orphaned - a record that exists and is no longer
  reachable through the surface built to read it. This is the sharper half.

Every day is re-tallied under the current basis, every run
: which is what makes [[SM338]]'s marker unable to do its main job here. The
  rows it produces are labelled honestly - they genuinely are recomputations -
  but no day ever reads as basis 1, because no day's bucket ever survives from
  before the upgrade.

Visitor-level state is rebuilt rather than carried
: [[SM213]]'s scanner map and [[SM332]]'s sweep set are recomputed from the full
  log on every call. That happens to be *correct*, and is more expensive than
  intended - worth stating because a future change that assumed they persisted
  would be wrong in a way this masks.

# Why fixing it is not a small change

Making the cache load for the first time is not a version-number correction. It
switches on incremental ingestion, offset reuse and bucket persistence
simultaneously, on the default path, for every site. Each of those is intended
behaviour that has never run in production.

The direction is right and the change is desirable. It needs to be the thing a
release is about.

# What to check when it is done

- Sabotaging the stored offsets changes the next run's output.
- A day whose log has rolled off is still present in the index, from its
  retained bucket.
- Day buckets written before an upgrade keep the basis they were counted under,
  which is what [[SM338]] intends and cannot currently deliver.
- The scanner and sweep maps carry across runs rather than being rebuilt, and
  the classification is unchanged when they do.
- Export time does not grow with retention.

# Related

[[SM338]] (whose historical-basis claim this falsifies on the default path, and
which has been corrected), [[SM339]] (the stamp and the recompute - this makes
the stamp more valuable still, since the index cannot supply the distinction at
all here), [[SM213]] (the visitor-level pass whose state this rebuilds), and
[[SM140]] (which introduced first-party ingestion and its offsets).
