---
title: "SM338 - a change in what a number means must be visible in the data"
subtitle: "SM329 changes what a page view IS. A closed day file is written once and never rewritten, so the series carries a permanent step at whatever date each instance upgrades - a metric change wearing the clothes of a traffic change, on a per-site date no changelog records."
brand: plain
status: shipped
status-note: "SHIPPED for 0.10.12, RAISED BY THE PARTNER AGENT while the release was already in the gate, and held the cut deliberately. The point is that it is cheap now and impossible afterwards: the discontinuity lands on the date each instance upgrades, which is per-site, so nothing recorded later can identify it. One small integer per day, written at the time. Inspecting the code to size the work found the problem was worse than reported - the CURRENT MONTH's rollup is refreshed on every call, so in the month an instance upgrades it sums days counted both ways into a single figure, and the month-on-month delta built from that figure is the first number anybody looks at. The BACKFILL the partner also proposed is NOT in this release and is filed as [[SM339]]."
---

# Why this could not wait for the next release

[[SM329]] stops an image counting as a page view. That is a change in what the
number means, not in the traffic it describes.

It lands on a store with a specific property: **a closed day file is written
once and never rewritten**. Every day already rolled up keeps its old,
asset-inflated `pageviews` for ever; every day after the upgrade does not. So
the series steps - and it steps on the date each instance happens to upgrade,
which is different for every site and recorded nowhere.

**This exact confusion has already happened once and could not be settled.** An
operator asked why traffic dropped on 27 July and assumed a new classifier had
gone in. Answering needed data from before `data_from`, which no longer existed,
and the honest conclusion was that the question would never be answerable. The
same question about this release's step is guaranteed to be asked, some weeks
later, by which time whoever changed the counting has moved on.

The remedy costs one small integer per day, written at the time. Written
afterwards it costs nothing, because afterwards there is nothing to write it
from.

# What inspection found that the report did not

The partner's reading was right about the day series. The month is worse.

The current month's rollup is **refreshed on every call**, so in the month an
instance upgrades it sums days counted one way and days counted the other into
one total. That total is not so much wrong as not a measurement of anything -
and `delta_pageviews`, computed from it, is the number on the front of the
month-on-month series.

A day is mixed too, on exactly one day: the day of the upgrade, whose bucket
receives events under both bases. That is why the basis is recorded as a **set**
rather than a scalar. A field that had to pick one would be lying on precisely
the day the reader most needs it.

# What shipped

```datatable
columns: Where | Field | What it answers
widths: 4cm | 4.6cm | X
bold: 1
tone: medium
---
Day rollup | `counting_basis` | Which basis this day's numbers were built under
Day rollup | `counting_basis_mixed` | True only on the upgrade day itself
Month rollup | `counting_basis` | The newest basis contributing to the total
Month rollup | `counting_basis_mixed` | Whether this total sums days counted differently
Index day row | `counting_basis` | Where the step is SEEN - this is the series a reader plots
Index month row | `counting_basis_mixed` | Guards the delta, which is the number that misleads
---
```

Two bases are defined, and what each means is written where the number is
produced rather than in a changelog:

```
  1 - assets counted as page views (up to and including 0.10.11)
  2 - assets counted separately, as asset_hits (SM329, from 0.10.12)
```

**A bucket carrying no basis at all is basis 1, never unknown.** Every existing
instance has day buckets in its export cache with no such key, and they were
definitely counted somehow. Reading them as unknown would discard the one fact
this exists to preserve.

# Measured against a real 0.10.11, not reasoned about

An instance was rolled up by v0.10.11 and then run under this release, on the
same store. Yesterday's traffic was one article and two images, which is the
asset inflation the field found.

```datatable
columns: Artefact | Before (0.10.11) | After the upgrade
widths: 4.6cm | 4.4cm | X
bold: 1
tone: medium
---
Yesterday's day file | `pageviews: 3`, no basis field | **byte-identical** - history untouched
Today's day file | - | `pageviews: 1`, `asset_hits: 1`, `counting_basis: 2`
Index row, yesterday | - | `counting_basis: 1`, derived
Index row, today | - | `counting_basis: 2`
The current month | `pageviews` summing both | `counting_basis_mixed: true`
---
```

**History is not rewritten, and that was checked by byte comparison rather than
by reading the code that promises it.**

## The asymmetry this exposed, stated rather than left to be found

A day file closed before the upgrade carries **no basis field at all**. The
basis-1 reading lives in the index, which is regenerated on every call from the
export cache.

So the two artefacts describing the same day answer differently: ask the index
and it says basis 1; ask the day file - the durable record, the thing that
outlives the cache - and it says nothing. Anyone reading day files directly
gets no marker, which is a weaker version of the defect this filing is about.

It is recorded here rather than fixed here, for the same reason as the backfill:
stamping closed day files is a **write over durable data**, and [[SM339]] is
already the release that opens those files. Doing both there, tested as the
thing being tested, is better than adding a second historical write to a release
already in the gate. The scope note is added to SM339.

**And the asymmetry is worse than a missing field.** The partner agent asked
whether the index's basis-1 reading survives losing the export cache. Measured:
it does not - and on a cold cache the reader re-tallies the historical days
under the current basis, so the index reports numbers the durable day files
contradict. Neither side is lying, and nothing says which one is being read.
That measurement is in [[SM339]], which it moves from housekeeping to a
correctness item.

# What was deliberately not done

**The backfill.** The raw first-party log is retained for `retention_days`, 90
by default, so the day rollups could be recomputed and the series made
continuous and correct rather than continuous and wrong. That is real and it is
[[SM339]]. It is not in this release, because a recompute is a **write over
durable data** and belongs in a release where it is the thing being tested
rather than a passenger on one already in the gate.

The two are not alternatives, which is how the proposal framed them. The marker
must be written by the release that changes the basis or the date is lost. The
backfill can be run later, and can only reach as far as retention - so recording
the basis is what makes a later backfill checkable, since a recompute needs to
know which days it changed.

# Verification

- A day counted after the upgrade records basis 2; a day rolled up before it
  reads as basis 1 rather than as unknown.
- The month an instance upgrades reports itself as mixed.
- The index day series carries the basis, so the step is visible where it is
  plotted rather than inferable from a changelog.
- A cache written by the previous release is read without loss.

# Related

[[SM329]] (the change of basis this records), [[SM339]] (the backfill),
[[SM327]] (the same principle applied to the perf baseline - re-capturing it
would have hidden the drift, and the reason not to was identical: a control
whose meaning changed without saying so), and
`inbox/archive/2026-08-16-visitor-stats-what-must-be-recorded-now.md`, whose
closing argument is that the analysis can be rewritten and the data cannot.
