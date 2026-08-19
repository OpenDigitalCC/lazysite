---
title: "SM393: the ordered trail is recorded, and it expires"
subtitle: "Sequence was deliberately held as aggregates so no visitor's path was retained. Order is the one fact that cannot be recomputed once the event ring rolls, and the ring is shortest on the busiest sites. The design choice is reversed on purpose, with the deletion shipping alongside the recording rather than after it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-19. Per visit, per day: ordered path sequence, entry, exit, distinct-page depth, per-step gap and the class as it was at the time, written to lazysite/stats/trails/YYYY-MM-DD.json - separate from the day files, which stay aggregates only. Limits ship with it: 40 steps per visitor, 2000 visitors per day, trails_retention_days default 30, trails: off to disable. Expiry runs on EVERY export including the ones with nothing to write, so a site whose traffic stops still ages out. Crawlers open no visit and leave no trail. Three defects were found and fixed while building it: the flush was missing from the path --export actually takes, its mkdir used File::Path which this plugin never loads (so it failed silently inside an eval and the directory was never created), and recount would have written every visit in the window a second time because trail files are appended to."
---

# What was asked for

The site agent asked for the ordered sequence per visitor per day -
entry, exit, depth, step timing and class at the time - stored in a
per-day file separate from the rollup, capped, with a stated retention.

# Why this is a reversal, and should be read as one

[[SM336]] chose the opposite, and said so in the code:

::: widebox
"A hundred visitors going `/ -> /products -> /contact` is one counter of
100 on each edge, **not a hundred stored journeys**: it reconstructs a
flow without retaining anybody's path."
:::

That was a defensible position, and it is being changed deliberately
rather than drifted away from. The reason it does not survive contact:

Aggregates can be recomputed from retained logs whenever the analysis
improves - that is what [[SM338]]'s basis stamp exists to manage.
**Order cannot.** Once the event ring rolls, "this visitor read pricing,
then case studies, then left from contact" is unreconstructable from any
rollup, for ever.

And the ring is smaller than it looks, in the wrong direction: its
retention is a function of **volume, not time**. Measured on edge at 8
events/hour it spans 26 days; at 200/hour about 24 hours; at 1000/hour
about 5 hours. The busiest sites - the ones with real visitors - keep the
**least** history, and anyone judging the window from a quiet instance
concludes it is generous.

# What is recorded

Per closed visit, per day, in `lazysite/stats/trails/YYYY-MM-DD.json`:

- the ordered path sequence, as visited, repeats included
- `entry` and `exit`
- `depth`, counting **distinct** pages, so a reload is not another page
- per step, the gap to the **next** step - the dwell on the page being
  left, which is what separates reading from scanning
- per step, the visitor class **as it was at the time**

An open visit has no trail: the record is written when the session
closes, so a visit is one record rather than one append per step.

# The deletion ships with the recording

A retention that arrives later is a retention nobody has, and this is the
most person-adjacent data the platform holds. So the limits are in the
same change:

- `$TRAIL_STEP_CAP` 40 steps per visitor - a longer trail is a crawl, and
  the shape of a crawl is already answered by the class
- `$TRAIL_VISITOR_CAP` 2000 visitors per day
- `trails_retention_days`, default 30
- `trails: off` disables recording; existing files still age out
- expiry is by **filename**, which is the day the file describes - no
  stat, no clock skew, and a file whose name is not a date is left alone
  rather than guessed at

# Three defects found while building it

Each was caught by a fixture that failed, and each is asserted against.

Flush on the wrong paths
: `_trails_flush` was wired before both `_save_export_cache` calls in
  `scan_first_party` and `scan_stats` - and `--export` goes through
  neither. It reaches `_export_assemble`, which saves the cache itself.
  Trails were recorded into the cache and never written.

mkdir that never ran
: the flush created its directory with `File::Path::make_path` inside an
  `eval`. This plugin **never loads File::Path**, so the call died, the
  eval swallowed it, `-d $dir` was false and the function returned. It
  now uses a plain `mkdir` per level, which is what `_ensure_dirs` in the
  same file already does. A first version of the test pre-created the
  directory and passed against the broken code; it no longer does.

recount would have doubled every trail
: `cmd_recount` deletes the day and month files for the covered window so
  they are rebuilt, then re-ingests. Trail files are **appended** to, not
  summed, so a recount would have written every visit in the window a
  second time. It now clears the trail files for those days too.

# And one found by sabotaging the test

Expiry sat at the end of the flush, **below** the "nothing new to write"
early return. A site whose traffic stopped, or one that switched trails
off, would have kept everything it ever recorded for ever. Expiry is now
its own function, called first and unconditionally. Today's file is never
past the cutoff, so expiring before writing is safe.

# What is deliberately not here

The brief scopes this to recording - "the recording is the cheap half, the
analysis can arrive whenever it is ready" - and this change is the recording.
It answers the two questions the brief left open: a per-day file separate from
the rollup, so the durable store's size stays predictable and trails can be
retired independently; and a stated 30-day retention, on the brief's own
reasoning that a short window is easier to defend than an unbounded one.

**The requester cannot read what this writes.** The site agent has no host
access and sees only what `analyse_visitors` returns, so until that tool gains
a trails selector the data accumulates for an operator on the box and for
nobody else. That is the right order - the recording cannot be backfilled and
the analysis can - but it should be stated rather than assumed, because a
feature whose requester cannot observe it is indistinguishable from one that
does not work. The manager Stats page is in the same position.

# Verification

`t/unit/plugins/13-the-trail-is-recorded-and-expires.t`, 16 assertions.
Seven sabotages were applied to the engine, each confirmed to apply and
still compile, and each fails the test: removing the recording; restoring
the `make_path`; disabling the unlink; leaving the recorded trails in the
cache so the next export re-appends them; raising the step cap; reversing
the step order; and moving expiry back below the early return.

`t/unit/plugins/14-trails-honour-their-configuration.t`, 7 assertions on the
configuration surface, against four more sabotages: ignoring `trails: off`;
ignoring the configured retention; making expiry a sweep rather than a cutoff;
and skipping expiry when trails are off. Its own first version was wrong in a
way worth recording - it placed a five-day-old file and expected the 30-day
default to delete it. The engine was right and the fixture was not, which is
the same trap as the `\x{e9}` fixture that was secretly ASCII: a fixture has
to establish the condition it claims to test.
