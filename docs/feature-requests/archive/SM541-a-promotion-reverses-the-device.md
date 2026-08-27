---
title: "SM541: a promotion reverses the device"
subtitle: "Reach-back reversal replays events without device or term, so devices and search terms drift on every late scanner promotion."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): the ring event now carries `device` as counted and, for a search term, `term_h` - the hash the tally keys sq_seen by, never the words, because the ring lives in the export cache on disk under the SM336 promise; _apply_event accepts either the raw term (an ingest) or the hash (a replay) and recovers the words for the sq map from sq itself, where they can only be if the floor was reached. Proving test t/unit/plugins/29-a-promotion-reverses-the-device.t counts a desktop visit and a term over the floor, promotes the visitor in a later batch and asserts the day rollup reports no human, no desktop, no phantom unknown device and no term. FOUND 2026-08-25 by the plugins structural review, PROVEN by probe tmp/plugins-probe-stats-device-reachback.pl; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. The ring events stored at stats.pl 2427-2444 never carry device or term, so when a late scanner promotion replays them with _apply_event(-1) the reversal decrements devices{unknown} while the original hit went to devices{desktop}. The probe shows batch2 human=0 scanner=2 devices={desktop:1} and a day file with classes.human=0 yet devices={desktop:1}. The fix stores device and term on the ring event so the reversal undoes what the hit did."
---

# The finding

Reach-back reversal in `plugins/stats.pl` replays ring events that carry
no `device` or `term` (`plugins/stats.pl 2427-2444` never store them), so
`_apply_event(-1)` decrements `devices{unknown}` while the original hit
went to `devices{desktop}`. The probe records `batch2: human=0 scanner=2
devices={"desktop":1}` and a day file with `classes.human=0` alongside
`devices={"desktop":1}`. Devices and search terms drift on every late
scanner promotion.

# Why it matters

Correctness: the device and search-term tallies stop agreeing with the
class tallies they sit beside. A day with zero human visits still
reports a desktop visitor, and the error compounds with each promotion.

# The proving test

NEW `t/unit/plugins/29-a-promotion-reverses-the-device.t` with
`is($day->{devices}{desktop} // 0, 0)`.

# Fix shape

Store `device` and `term` on the ring event at 2427-2444 so the reversal
replays the same fields the original application used.
