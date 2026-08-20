---
title: "SM424: the visitor stats page, and where the auto-blocker belongs"
subtitle: "Operator-reported congestion: one page renders every stats block at once. Proposal splits it, and moves the blocked-address list to Plugin Config, where the thing that owns it lives."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 from an operator-reported usability brief (archived at inbox/archive/), revised the same day so the blocked-address list moves to Plugin Config rather than to a stats-adjacent page of its own. NO DEFECT - this is usability plus one small correctness item. P1-P3 are a restructure of one starter page plus nav. P4 moves the blocked list to Plugin Config with two small engine additions (a per-entry disabled flag in the store, and a toggle action) and corrects SM128 copy that currently describes the enforcement path inaccurately. The stats-exclude list is optional and separate. WHY THE MOVE IS THE INTERESTING PART: the auto-blocker is not a webstats setting - it is enforcement, and it was on the stats page because that is where its DATA was visible, which is the reasoning that puts a control where its evidence appears rather than where its owner lives. SIZE: M, mostly starter-page work; post-beta."
---

# The shape

One page renders every block: visits, depth, entry and exit pages, devices,
search terms, journeys, trails, and the blocked-address list. An operator
looking for one of them scrolls past all of them.

The brief's split is P1-P3 (paginate/restructure plus nav) and P4 (relocate the
blocker to Plugin Config). P4 carries the only engine work: a per-entry
disabled flag and a toggle action, plus truthful copy about what SM128 actually
enforces.
