---
title: "SM339 - recompute the day rollups so the series is continuous and correct"
subtitle: "The raw first-party log is retained for 90 days, so every day rollup inside the retention window can be rebuilt under the current counting basis. The window shrinks by one day per day, and what falls out of it is unrecoverable."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-17 (ffb4204), with [[SM341]] and [[SM343]] as one change. `--recount` is DRY RUN BY DEFAULT, because it writes over the only durable record a site has; BOUNDED by the retained logs, because that is all it can honestly rebuild, and days older keep their figures and keep saying which basis produced them; and it reports per-day before and after, because "it ran" is not a result. Durable files are written canonically now, so a repair is checkable with plain `diff`."
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

# This is now a REPAIR, not only a re-basing

[[SM343]], found after this was filed: a closed day file is frozen at the last
export call made **during** that day, and never revisited. So it is short by
everything that happened afterwards - and a day file is complete only if nobody
looked at the statistics that day.

That changes what this filing is for. It was written to make the series
comparable across a basis change. It would also, in the same pass and from the
same raw logs, make the durable record **complete** - which is a larger and more
straightforward benefit than the one it was filed for.

It also removes an objection. "A recompute writes over durable data" was the
reason to be careful, and it assumed the durable data was right. For any day
with traffic after its last call, it is not: the recompute replaces a partial
record with a complete one, which is a repair rather than a rewrite.

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

## Measured: the derivation does NOT survive a cold cache

The partner agent asked whether the index's basis-1 reading for a historical day
is a property of the day file - in which case the stamp is a convenience - or of
the export cache, in which case it is the only durable record. The question
decides how hard this filing should argue for it, so it was run rather than
reasoned about: roll a store up under v0.10.11, upgrade, then delete
`lazysite/cache/stats-export.json` and export again.

```datatable
columns: | 2026-08-15 (historical) | 2026-08-16 (today)
widths: 5.4cm | 4.6cm | X
bold: 1
tone: medium
---
Index, warm cache | `pageviews 3`, basis **1** | `pageviews 1`, basis 2
Index, cold cache | `pageviews 1`, basis **2** | `pageviews 1`, basis 2
The day file, throughout | `pageviews 3`, **no basis field** | -
---
```

**It is cache-resident.** So the stamp is not a convenience. It is the only
durable record of the basis, and this filing should say so.

## And the disagreement is about the number, not only the marker

The more interesting half. On a cold cache the reader's offset returns to zero,
it re-reads the whole retained log, and it **re-tallies the historical days
under the current basis** - so the index reports `pageviews 1` for a day whose
durable file says `pageviews 3`.

Stated fairly: the index is not lying. Those rows genuinely are basis-2 data and
they are labelled basis 2 correctly. What has happened is an **accidental,
partial, undeclared backfill** - this filing's own job, performed by losing a
cache file, reaching only as far as the raw logs go, and leaving the durable
store untouched and stale.

So which history a reader gets depends on whether the cache has been cleared
since the upgrade, and nothing anywhere says which they are looking at.

**How reachable is that?** Not routine: the Hestia deploy removes
`cache/tt` and not the stats cache. But a vhost rebuild takes the docroot with
it, which is [[SM270]]'s scenario and does happen in the field, and any operator
clearing caches by hand will do it.

This does not block the release that introduces it - the numbers on both sides
are internally consistent and the raw material for the real fix is intact, so
there is no "cheap now, impossible later" here of the kind that held 0.10.12 for
[[SM338]]. It does raise this filing's priority from housekeeping to a
correctness item, and it adds a requirement below.

# Confirmed on deployment: the stamp does not reach the durable store

Measured on edge immediately after 0.10.12 landed:

```datatable
columns: Artefact | counting_basis
widths: 6.4cm | X
bold: 1
tone: medium
---
Index rows (35) | present - 34 at basis 1, one at basis 2
Current month, 2026-08 | present, basis 2, mixed true
Closed month, 2026-07 | **absent** - file unchanged by the upgrade
Closed days, 07-18 and 08-10 | **absent** - files unchanged
---
```

The mechanism is [[SM343]]: a closed file is written once, so it can never
acquire a field added after it was written. The index compensates by reading an
unstamped day as basis 1.

**And that is correct by inference rather than by construction**, which is the
partner agent's framing and sharper than the way this was first recorded. The
rule is "unstamped means basis 1". A day whose file were ever rewritten under a
later basis WITHOUT gaining a stamp would still read as basis 1, and nothing
would catch it. So [[SM338]]'s protection currently lives in the derived view
rather than in the durable artefact it exists to protect - the inverse of the
intent.

[[SM341]]'s timestamp will hit the same barrier for the same reason. Three
filings, one barrier, one insertion point.

## And it makes the recompute the only route to a correct history

A second consequence, from the same measurement. [[SM329]]'s asset exclusion
applies to basis-2 ingestion only, and every historical day is basis 1 and stays
that way - correctly, because that IS what [[SM338]] preserves. So those days
keep their asset-inflated pageviews permanently unless something recomputes
them.

The partner agent found this by noticing two of their own predictions were
incoherent: they predicted both that history would be preserved and that
historical counts would fall, and only one can be true. Worth recording, because
the same contradiction is easy to hold about this filing - "the marker protects
history" and "the fix corrects history" are not both available without a
recompute.

# Write the durable files canonically, or the test cannot be a diff

Raised by the partner agent before this was built rather than after, and checked
rather than assumed: `_write_json_atomic` uses `encode_json` with no `canonical`
flag, so **key order is randomised per process**. Verified by writing the same
content twice - the bytes differ.

Today that costs nothing, because day files are write-once and an unrewritten
file is byte-identical trivially. This filing changes that. A repaired file will
differ in bytes from its predecessor even in fields it did not touch, so:

- any acceptance test for this work must compare **semantically**, not with
  `diff`, and
- the same is true for anyone auditing the store afterwards.

Switching those writes to canonical encoding is close to free and makes the
durable artefacts diffable - which is what makes a repair auditable by anybody,
including an operator with no tooling. It belongs in this change because this is
the change that starts rewriting them.

# Sketch

A `--recount-days` verb on the stats plugin, refusing by default and requiring
an explicit range or `--all`, reporting per day: recomputed, unchanged, or
skipped because the log has aged out. Dry-run first, showing the before and
after for each day without writing.

# Verification

- A day recomputed from its raw log has `pageviews` lower by exactly the
  `asset_hits` it gains, and every other field unchanged - **except where
  [[SM343]] applies**, in which case it is also higher by the traffic the
  partial file never recorded. Those two move in opposite directions, so the
  check must account for both rather than expecting a clean subtraction.
- A day whose log has aged out is reported as skipped and left alone, still
  reading as basis 1.
- The verb refuses to run without an explicit range, and has a dry run that
  writes nothing.
- Running it twice changes nothing the second time - which requires canonical
  encoding to be checkable by comparison at all.
- The series after a full recompute has no step at the upgrade date, and the
  days it could not reach still say which basis they are.
- **A cold cache does not silently change history.** After deleting the export
  cache and re-exporting, the index and the durable day files agree about every
  historical day - or the disagreement is reported rather than served.

# Related

[[SM338]] (the marker, which shipped, and which is what makes a recompute
checkable - it tells the operator which days changed basis), [[SM329]] (the
change of basis), and
`inbox/archive/2026-08-16-visitor-stats-what-must-be-recorded-now.md`.
