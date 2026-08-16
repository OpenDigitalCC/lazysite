---
title: "SM339 - recompute the day rollups so the series is continuous and correct"
subtitle: "The raw first-party log is retained for 90 days, so every day rollup inside the retention window can be rebuilt under the current counting basis. The window shrinks by one day per day, and what falls out of it is unrecoverable."
brand: plain
status: candidate
status-note: "FILED 2026-08-16 alongside [[SM338]], which shipped. SM338 records that the basis changed; this makes the series comparable across the change. Deliberately NOT bundled into 0.10.12: a recompute is a WRITE OVER DURABLE DATA - the one store this project has been most careful with - and it belongs in a release where it is the thing being tested rather than a passenger on one already in the gate. The cost of waiting is bounded and known: one day of recoverable history per day, out of ninety."
---

# What is possible, and for how long

`plugins/stats.pl` reads `lazysite/logs/access-YYYYMMDD.jsonl` - one line per
request, retained by `retention_days`, default 90. Every field the day rollup is
built from is in there.

So for the retention window, and only for it, the rollups can be recomputed
under the current basis. After [[SM329]] the historical days are the ones with
assets folded into `pageviews`; a recompute would make them comparable with the
days that follow, and would populate `asset_hits` for them - which is the number
that makes the drop **explicable** rather than merely flagged.

The window shrinks by one day per day. What leaves it cannot be rebuilt from
anything.

# Why this is not urgent in the way SM338 was

[[SM338]] had to ship with the basis change or the discontinuity date was lost,
because it lands on the date each instance upgrades and nothing else records
that. This has no such deadline inside the next few releases - it has a slow,
quantified one.

That difference is the whole reason these are two filings rather than one.

# What makes it delicate

**It writes over durable data.** The day store is the only durable record; the
export cache is transient and the raw logs age out. A recompute that got the
basis, the classification or the capping subtly wrong would replace a correct
old-basis record with an incorrect new-basis one, and the original would be gone.

**It must be an explicit verb, not a migration.** An upgrade that silently
rewrote a site's history would be the wrong shape even if the arithmetic were
perfect - the operator has to choose it, and be able to see what it did.

**It has to be checkable.** The recomputed day should be comparable against what
was there before, and the difference should be attributable: `pageviews` falls
by exactly the `asset_hits` it gains, or the recompute is doing something else
as well and wants explaining before it is trusted.

**It cannot recompute what the logs no longer hold.** Days outside retention
keep their old basis and must keep saying so - which they will, because SM338
reads a missing marker as basis 1. A partial recompute leaves a series that is
correct at both ends and steps in the middle, and that step is now labelled.

# Added scope, from SM338's measurement

A day file closed before 0.10.12 carries **no basis field at all**. [[SM338]]
puts the basis-1 reading in the index, which is regenerated from the export
cache - so the durable record itself, the artefact that outlives the cache, is
silent about which basis it was built under.

Stamping those files with `counting_basis: 1` belongs here rather than in
SM338, because this is the release that opens historical day files anyway.
Doing it here means one release performs one kind of historical write, and it is
the thing being tested.

It is also strictly easier than the recompute and should not be gated behind it:
a stamp adds a derivable field and changes no number, so it can ship even if the
recompute is judged too risky. If only one of the two happens, it should be this
one.

# Sketch

A `--recount-days` verb on the stats plugin, refusing by default and requiring
an explicit range or `--all`, reporting per day: recomputed, unchanged, or
skipped because the log has aged out. Dry-run first, showing the before and
after for each day without writing.

# Verification

- A day recomputed from its raw log has `pageviews` lower by exactly the
  `asset_hits` it gains, and every other field unchanged.
- A day whose log has aged out is reported as skipped and left alone, still
  reading as basis 1.
- The verb refuses to run without an explicit range, and has a dry run that
  writes nothing.
- Running it twice changes nothing the second time.
- The series after a full recompute has no step at the upgrade date, and the
  days it could not reach still say which basis they are.

# Related

[[SM338]] (the marker, which shipped, and which is what makes a recompute
checkable - it tells the operator which days changed basis), [[SM329]] (the
change of basis), and
`inbox/archive/2026-08-16-visitor-stats-what-must-be-recorded-now.md`.
