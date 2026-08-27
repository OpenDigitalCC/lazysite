---
title: "SM340 - the first-party export cache is written every run and never read"
subtitle: "The loader accepts version 1. The first-party path writes version 2. So the default statistics path discards its cache on every call, re-reads every retained log, and rebuilds every day bucket from scratch - and its per-file byte offsets, the entire point of the incremental design, have never once been used."
brand: plain
status: shipped
status-note: "SHIPPED for 0.10.12. The release manager held the cut for it rather than carrying it forward, because [[SM338]] is defeated by it rather than merely unhelped: a marker that records which basis a day was counted under is worthless while every day is recomputed on every call. Four things went in - the loader accepts both cache shapes; the promotion REACH-BACK, which is the regression the fix would otherwise have introduced; the export's event list became an explicit projection so internal fields cannot be published by sharing a hash; and the stats path got bench coverage, which it had never had. FOUND by sabotage rather than by reading, and the first attempt at the fix reproduced the bug for a different reason - see below. NOT re-baselined: the new op's figure is a first measurement, the other ops are untouched per [[SM327]]."
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

# Measured on a live instance, from the partner surface

Reported by the partner agent against edge/0.10.11, which has 34 days of logs
and is a quiet site:

```datatable
columns: Call | Time | What it shows
widths: 4.6cm | 2.2cm | X
bold: 1
tone: medium
---
`window=1` | 3301 ms | -
`window=7` | 3609 ms | -
`window=30` | 4028 ms | -
`window=365` | 4102 ms | **asking for one day costs what asking for a year costs**
same call, 1/2/3 | 4256 / 4117 / 4108 ms | **no warm-up at all** - a loaded cache would make the second cheap
`day=2026-07-18` | 3332 ms | a closed day, already a file on disk, and the whole log is re-ingested before it is consulted
`whoami` / `list_pages` | ~500 ms | the same surface's baseline
---
```

Roughly **3 to 3.5 seconds of pure re-ingestion on every call**, independent of
what was asked for. That is the signature of the defect stated as a cost rather
than as a version mismatch.

**It grows.** The work is linear in retained log volume and `retention_days`
defaults to 90, so a busy site three months in pays this on every stats page
load, every export and every agent call, increasing daily until retention starts
trimming. Nobody has met it yet because nobody has had ninety days of real
traffic on a site with this path enabled.

## And this path has no performance coverage whatsoever

The partner's inference was that the current bench figures for this path measure
the broken behaviour and so are not a baseline the fix should be compared to.
Checked rather than accepted: `tools/bench.pl` contains **no reference to stats
or export at all**. There are no figures for this path, broken or otherwise.

The accurate statement is worse than the one proposed. A 3.5-second per-call
cost on the default statistics path went unmeasured because nothing measures it,
and it was found from outside by an agent timing its own tool calls.

That is [[SM327]]'s finding in a harder form. There the complaint was that a 2x
tolerance permits unbounded accretion; here an entire surface sits outside the
gate, so no tolerance applies at any value. The fix should arrive with bench
coverage for this path, and the first figures taken after it should be captured
as the baseline rather than compared to anything.

# What shipped

## The loader, and the trap in the first attempt at it

The fix is that `_load_export_cache` accepts both shapes and each ingester
normalises the one it gets. The intent was already written down - the
server-log path's own comment says "a v2 first-party cache lands here too and
resets to the server-log shape", which it could not do while the loader refused
to hand one over.

**The first attempt reproduced the bug for a completely different reason.** It
declared `our %CACHE_SHAPES = ( 1 => ..., 2 => ... )` beside the loader. The
dispatch that reaches the loader runs EARLIER in the file than that line, so the
hash was still empty when consulted and every cache was rejected exactly as
before. This file already carries three comments warning about that trap for its
regexes and its month map, and it caught this too. It is a sub now, which is
bound at compile time and cannot be read before it is assigned.

Worth recording because the symptom was identical and the sabotage test caught
it immediately, where re-reading the diff would not have.

## The reach-back, which is the regression the fix would have introduced

While the cache was discarded on every call, a probe arriving late always
reclassified that visitor's earlier requests - by brute force, because the whole
log was re-read. With the cache honoured, those events are already counted under
`human` and the promoting batch has to reach back for them.

That matters precisely because the scanner's homepage hit is what [[SM213]]
classifies per visitor to remove, and [[SM332]] needs five distinct 404s that
may well arrive either side of a call. Measured on a fixture before the
reach-back was built: a sweeper's first three requests stayed `human`, including
the homepage hit, and only the batch that crossed the threshold was `scanner`.

So the per-event tally is now a single reversible function applied with `+1` or
`-1`, rather than a second copy of the counting written to match the first. On
promotion, the token's earlier events are reversed under their old class and
re-applied as `scanner` - aggregates included, not merely the labels. Bounded by
the event ring, which is capped; what has scrolled out keeps the class it was
counted under, which the export's own note already describes as a bounded sample
rather than the dataset.

## The export stopped handing out its internal ring

The reach-back needs each event's day and referrer. Those live in the cache
ring, and `_export_assemble` published that ring **verbatim** - so adding a
field for internal use would have published a referrer attached to a visitor
token, a privacy change arriving as a side effect of a performance fix. The
exported event list is now an explicit projection of the five published fields.

# What it is worth, measured rather than claimed

The same 30-day, 4,500-event fixture exported repeatedly under v0.10.11 and
under the fix:

```datatable
columns: | ms per call
widths: 8.4cm | X
bold: 1
tone: medium
---
v0.10.11, cache never read | 630.7
fixed, cache read | 424.9
---
```

**These figures do not transfer to the field, and the first version of this
section wrongly implied they did.** It attributed the gap to the calling
surface's overhead and to corpus size. Those are real and they are not the
main term.

The measurements were taken on different machines doing different work:

development host
: a local, uncontended, fast disk, running the engine directly.

the instrument
: a hosted site on a busy shared server, read over MCP, with the disk
  contended by every other tenant on it.

This operation is I/O-bound at both ends - it reads every retained log and
rewrites four files per call - so disk contention is not a modifier on the
result, it is a substantial part of what is being measured. A saving of 206 ms
here says almost nothing quantitative about what the same change removes there.

What DOES transfer is the direction and the shape: the re-ingestion term is
removed, it is linear in retained log volume, and the assembly term remains and
is paid on every call. What does not transfer is any number.

Stated this way because the temptation was twice to quote something convenient -
first the field's 3.5 seconds as though it were the saving, then this fixture's
third as though it predicted the field's.

**The correctness half is the justification.** History survives, a day whose log
has rolled off no longer disappears from the index, and [[SM338]]'s marker can
do the job it was written for.

# Confirmed in the field, 2026-08-17

Measured on edge by the partner agent, same script and same corpus either side
of the upgrade, so this is a within-host before-and-after and inherits none of
the confound in [[SM342]].

```datatable
columns: Call | 0.10.11 | 0.10.12 | Change
widths: 4cm | 2.4cm | 2.4cm | X
bold: 1
tone: medium
---
`index` | 3486 ms | 966 ms | **3.6x**
`day` (a closed day) | 3465 ms | 1052 ms | **3.3x**
`window`, 1.1 MB | 4193 ms | 1824 ms | 2.3x
surface floor (`whoami`) | 484 ms | 421 ms | unchanged, as it should be
---
```

Subtracting the floor, the day call's engine term went from **~2.98 s to
~0.63 s**. So re-ingestion was about **80% of per-call cost** on a real
instance - considerably more than the third this development host showed, which
is exactly what [[SM342]] predicts: the saving is I/O and the field is where I/O
hurts.

**And the matched pair holds.** The index row and the durable day file for
2026-07-18 both read 848 pageviews at basis 1. Before the fix the index would
have reported a recomputed figure the file contradicted. That is this defect
closed on live traffic, and it could only have been demonstrated from outside.

# The gate gap, closed

`tools/bench.pl` had no reference to stats or export at all, which is why a
per-call cost of this size went unmeasured. It now has a `stats_export_ms` op
with a fixture carrying thirty days of first-party logs - an op pointed at an
empty fixture would report a fast, stable, meaningless number, which would be a
poor way to introduce coverage for a bug that was itself a control doing
nothing.

**And the check itself was hiding one.** An op with no baseline figure did
`or next` - silently. So adding an op to that file LOOKED like coverage while
being compared to nothing, and the gate would still report all ops within
tolerance. It now names the ops it did not check and says a baseline must be
captured before the gate can be relied on for them.

`stats_export_ms` has been given a baseline figure and **the other ops were left
exactly as they were**. This is a first measurement of an op that had none, not
a re-capture - [[SM327]] records that re-capturing the others would bake in a
measured 9-26% drift and remove the ability to see it.

# What the fix does NOT remove, and why that matters to a reader

The write side is **unconditional**. Verified by calling twice with no new log
lines and comparing mtimes: today's day file, the current month, the index and
the cache are all rewritten on a call with nothing whatever to ingest.

That is the floor under the remaining cost, and it is worth stating plainly
because it makes a suspiciously good benchmark diagnosable. A call that came
back at roughly the surface's own overhead would mean essentially zero engine
work - which cannot be true while those four rewrites happen. Such a result
would be the cache serving without refreshing: a new defect wearing the costume
of a good number.

It also says where the next improvement is, if one is wanted. The remaining cost
scales with the number of DAYS held rather than with events, since it walks the
day buckets and rewrites the month and index every call - and being writes, it
is the part that suffers most on a contended disk, which is where real sites
live and where this was never measured. Rewriting a closed
month that cannot have changed is the obvious candidate, and it is not attempted
here.

# Why this was not a version-number correction

Recorded because it was filed as "not a small change" and then done, and the
reason it was not small is worth keeping: making the cache load for the first
time switches on incremental ingestion, offset reuse and bucket persistence
simultaneously, on the default path, for every site. Each was intended
behaviour that had never run in production.

The reach-back is what that cost in practice. A one-line loader fix would have
passed the entire suite - it did - while quietly degrading the classification
SM213 and SM332 exist to produce, because nothing in the suite exercised a
promotion arriving after the events it should govern.

# What to check when it is done

- Sabotaging the stored offsets changes the next run's output. **Set them to
  the file's actual size, not past the end** - an over-long offset is reset to
  zero by the truncation guard, correctly, so that version of the probe reads
  the same whether the cache is honoured or not and proves nothing.
- A day whose log has rolled off is still present in the index, from its
  retained bucket.
- Day buckets written before an upgrade keep the basis they were counted under,
  which is what [[SM338]] intends and cannot currently deliver.
- The scanner and sweep maps carry across runs rather than being rebuilt, and
  the classification is unchanged when they do.
- Export time does not grow with retention, and `window=1` costs materially
  less than `window=365`.
- The stats path is in `tools/bench.pl`, and its first post-fix figures are
  captured as a baseline rather than compared to figures that never existed.

# Related

[[SM338]] (whose historical-basis claim this falsifies on the default path, and
which has been corrected), [[SM339]] (the stamp and the recompute - this makes
the stamp more valuable still, since the index cannot supply the distinction at
all here), [[SM213]] (the visitor-level pass whose state this rebuilds), and
[[SM140]] (which introduced first-party ingestion and its offsets).
