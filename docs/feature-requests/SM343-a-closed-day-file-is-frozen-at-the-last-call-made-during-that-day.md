---
title: "SM343 - a closed day file is frozen at the last call made during that day"
subtitle: "Today's rollup is refreshed on every call; a closed day is written only if no file exists. So a file created while the day was still running is never revisited, and holds the day as of the last export call made during it. A day file is complete only if nobody looked at the statistics that day."
brand: plain
status: candidate
status-note: "FILED 2026-08-17 from a partner-agent measurement on edge/0.10.11 - a day file and the window's own by_day row disagreeing about the same closed date, scanner by 5.6x - and reproduced here immediately. PRE-EXISTING and not introduced by 0.10.12, which is why the release was not held for it a second time: the recomputed views have always been right and the durable file has always been short, and nothing in this release changes either. But it lands on the artefact [[SM338]] just started stamping and the one [[SM339]] proposes rebuilding, and it changes SM339 from a nicety into a repair."
---

# Reproduced

Ten requests on one day. An export called after the first three - a Stats page
loaded mid-afternoon, an agent poll, anything - and then nothing until the next
day.

```datatable
columns: Source | Figure | What it is
widths: 5cm | 2.4cm | X
bold: 1
tone: medium
---
The durable day file | **3** | what survives log retention
The index | 10 | recomputed from the buckets
Actually in the log | 10 | -
---
```

The file is short by everything that happened after the last call, and it is
never corrected.

# The mechanism

`_persist_durable` writes a day file when the day is **today**, refreshing it on
every call, and otherwise only when no file exists:

```perl
next unless $day eq $today || !-f $path;
```

Both halves are individually reasonable. Together they mean a file created at
14:00 on Tuesday is Tuesday's permanent record, and Tuesday's evening never
reaches it - because by the time anyone calls again, Tuesday is no longer today
and its file already exists.

**So a day file is complete only if no export ran during that day.** A busy
instance whose operator checks the statistics daily has a durable store made
entirely of partial days; a site nobody looks at has a correct one. That is the
opposite of the behaviour anyone would assume, and it is invisible from the
outside because every view except the day file itself is recomputed and right.

# Why this was found now, and not before

Nothing surfaced it because the two artefacts were rarely compared. The partner
agent compared them while rehearsing a capture, and the disagreement was large
enough to notice: `scanner` at 183 in the day file against 1021 in the window
for the same date. Scanner traffic arrives overnight, which is exactly the
window a daytime call cannot capture.

Their reading of the cause was different from the actual one - they suspected
the two counting sites [[SM329]] had to fix in parallel, which is a reasonable
inference from that filing's own status note. It is not that. Both views are
computed by the same code from the same buckets; the difference is *when* the
file was frozen.

Worth recording because the observation was right and the diagnosis was wrong,
and the observation was the valuable half.

# What it interacts with

[[SM338]] stamps the counting basis
: the stamp is accurate about the basis and sits on a record that may be short.
  It does not make SM338 wrong - a partial day counted under basis 1 really was
  counted under basis 1 - but a reader trusting the stamp is trusting a figure
  that has a second, unrelated problem.

[[SM339]] proposes recomputing the day rollups
: this changes that filing from a nicety into a repair. It was written to make
  the series comparable across a basis change; it would also, in the same pass,
  make the durable record complete for every day still inside the retention
  window.

[[SM341]] proposes a `generated` timestamp
: it would have made this self-evident. A day file stamped 14:07 for a day that
  ran to midnight announces its own truncation, and nobody would have had to
  compare two views to find it.

**The three of them are one change**, and this is the argument that settles it:
recompute the day rollups, stamp each with the basis it was counted under and
the time it was written. After that a day file is complete, says what rule it
followed, and says when it was made.

# What it costs, over time

Every day that passes makes one more partial day permanent, because the raw
logs age out at `retention_days` and after that the day file is all there is.
Same clock as [[SM339]], and the same argument for not deferring indefinitely.

# What it does NOT affect

The recomputed views - the window, `by_day`, the index, the month rollups - are
built from the day buckets and have always been right. Anyone reading those,
which is most callers, has been reading correct figures.

# Verification

- A day with traffic after the last export call of that day has a day file
  matching the log, not matching the moment of that call.
- A day file already written is corrected when the day closes, or the design
  states plainly why it is not.
- A closed day's file and the index agree about that day.

# Related

[[SM339]] (the recompute, which this makes a repair), [[SM341]] (the timestamp
that would have made it self-evident), [[SM338]] (the basis stamp this sits
under), [[SM340]] (the other defect in this store found the same week), and
[[SM329]], whose status note about two counting sites prompted the partner's
diagnosis - a reasonable inference, and not the cause here.
