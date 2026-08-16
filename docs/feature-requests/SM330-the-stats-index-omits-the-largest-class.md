---
title: "SM330 - The statistics index omits the largest traffic class"
subtitle: "analyse_visitors index:true returns per-day rows carrying human, ai, bot and noise - and not scanner, which on the instance measured is 71.7% of all traffic. The rollup holds it; only the projection drops it."
brand: plain
status: candidate
status-note: "FILED 2026-08-16 from a partner-agent review of visitor statistics on edge/0.10.10. No data is lost - the durable day rollup carries scanner correctly and the windowed view reports it. What is wrong is the index projection, which appears to enumerate the classes and silently omits one. A caller reading the index to find the busiest day, or to decide which day to fetch in full, is reading a number that excludes most of the traffic."
---

# SM330 - the class that is not in the list

## What was measured

On edge, 0.10.10:

```
analyse_visitors { index: true }
  -> { "date": "2026-07-14", "human": 94, "ai": 94, "bot": 4,
       "noise": 14, "pageviews": 94 }
```

Four class keys, and no `scanner`.

The same day fetched in full:

```
analyse_visitors { day: "2026-07-18" }
  -> classes: { "human": 848, "scanner": 413, "bot": 107,
                "ai": 84, "noise": 99 }
```

Over the 30-day window, scanner traffic is **71.7% of all visits** - 8,269 of
11,530. It is the largest class on the instance by a wide margin, and it is the
one the index does not mention.

## Why the omission matters

**The index is the discovery surface.** It exists so a caller can see what data
is available and choose what to fetch. A caller scanning it for the busiest day,
or for an anomaly worth investigating, is working from figures that exclude most
of the traffic.

**It reads as complete.** The row carries four of the five class names. Nothing
signals that a fifth exists. An agent - or a person - building a report from the
index has no reason to suspect an omission, which is a different and worse
failure than a field that is obviously absent.

**Scanner is the class most likely to explain a day.** A day with 2,670 scanner
hits and 251 human ones looks, in the index, like an ordinary quiet day. The
thing that made it unusual is the field that was dropped.

**It undercuts the work that produced it.** [[SM213]] introduced visitor-level
scanner classification specifically so that probe traffic could be separated
from people, and [[SM192]] before it. That separation is the product of the
feature; leaving it out of the summary hides the answer the feature exists to
give.

## Bounded

Worth stating plainly, because it changes the priority: **no data is lost**. The
durable per-day rollup stores `classes` complete, including scanner, and the
windowed view reports it correctly. Nothing needs re-gathering and nothing is
unrecoverable. This is a projection that drops a field on the way out.

That is also why it has gone unnoticed: every other surface is right.

## The fix

Include `scanner` in the index rows.

Then consider whether the projection should be built from the class list rather
than from an enumerated set of keys, so that the next class added is present
everywhere by default instead of in every place somebody remembered. The rollup
already stores `classes` as a hash; emitting it whole, or iterating the same
list the rollup uses, removes the opportunity to forget one.

A second question worth settling at the same time: the index row reports
`pageviews`, which is human-only, alongside class counts that are not. Two
numbers in one row measuring different populations invite exactly the arithmetic
that produced this filing. Either name it `human_pageviews`, or report a total
beside it, so the row is self-consistent.

## Verification

- An index row carries every class the day rollup holds, scanner included.
- A day whose traffic is overwhelmingly scanner is visibly so from the index
  alone.
- Adding a hypothetical sixth class to the rollup makes it appear in the index
  without a second edit.
- The windowed and single-day views are unchanged.
- The class totals in an index row and the same day fetched in full agree.

## Related

[[SM213]] (the durable store and the index this projects from), [[SM192]] (the
scanner and noise classification whose result is being omitted), and
`inbox/visitor-stats-what-must-be-recorded-now-2026-08-16.md`, the review this
came from.
