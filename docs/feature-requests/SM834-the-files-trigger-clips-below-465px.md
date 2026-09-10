---
title: "SM834: the Files trigger goes past the viewport edge below about 465px"
subtitle: "Sites agent, 1311E-04, 2026-09-10: 33 of 33 rows clipped at 420px, on the one list of four whose table carries a fixed content width - and nothing breaks at the 1000px breakpoint that was expected to"
brand: plain
standard-margins: true
status: candidate
---

# What was measured

The labelled trigger from [[SM816]] was expected to cost width and break at the
1000px drawer breakpoint. It does not:

| Width | Connectors | Data | Backups | Files |
| --- | --- | --- | --- | --- |
| 1200 | clean | clean | no chevrons | clean |
| 1000 | clean | clean | no chevrons | clean |
| 980 | clean | clean | no chevrons | clean |
| 760 | clean | clean | no chevrons | clean |
| 420 | clean | clean | no chevrons | **33 of 33 past the edge** |

No wrapping anywhere, no page-level horizontal overflow anywhere, and the
trigger is 36px tall at every width on every list. **The breakpoint is fine.**

Files alone degrades, and the threshold is where its own table runs out:

| Viewport | Wrap client | Wrap scroll | Trigger px past the edge |
| --- | --- | --- | --- |
| 465 | 401 | 435 | 0 |
| 445 | 381 | 435 | 9 |
| 425 | 361 | 435 | 29 |
| 405 | 341 | 436 | 50 |

# The cause is the table, not the trigger

That table has a fixed content width of about 436px. Below roughly 465px of
viewport the content no longer fits, and the trigger - being the last column -
is what leaves the screen. The wrap scroll width stays at 435 while the client
width falls, which is the fixed width refusing to give.

So this is not [[SM816]] regressing: the trigger is simply the thing standing at
the edge when the edge arrives. Any content in that column would clip.

# The shape

The narrow case wants the table to stop insisting on 436px - the `min-width: 0`
already applied to the other manager tables, so the column can shrink and the
wrapper's own horizontal scroll takes over, which is the idiom the other three
lists use and the reason they are clean at 420px.

Worth confirming the wrapper scrolls rather than the page: a page-level
horizontal scrollbar would be a worse answer than clipping, and the measurement
above records no page overflow today.

# Priority

Low, and recorded rather than urgent. 420px is a small phone in portrait, the
manager is an operator surface, and the other three lists are clean. It belongs
in the batch that next touches the manager stylesheets, where it is a
one-property change in three files kept in step.

# Related

[[SM816]] (the trigger gained a word - the change this was testing for
regressions from, and did not find one), [[SM819]] (the three-column row, which
is what keeps the other lists clean).
