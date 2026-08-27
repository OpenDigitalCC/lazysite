---
title: "SM424: the visitor stats page, and where the auto-blocker belongs"
subtitle: "Operator-reported congestion: one page renders every stats block at once. Proposal splits it, and moves the blocked-address list to Plugin Config, where the thing that owns it lives."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL - the congestion is fixed on one page; the brief's THREE-PAGE SPLIT is not built, and P4 is not built. WHAT SHIPPED: every section of the stats report is now a collapsible block, the open set is remembered per viewer, and the two whole cards below it - Visitor journeys and Blocked IPs - collapse the same way and DO NOT FETCH until they are opened, so the page that previously called loadBlocked() on every load now costs that request only when somebody looks. Who's calling, Hits per day and Top pages stay open by default, because collapsing the answer to the common question would have traded one annoyance for another. WHERE THIS DEPARTS FROM THE BRIEF, and it is a real departure the operator should rule on: the brief proposed splitting the page into P1 dashboard, P2 detail and P3 journeys. This does not do that. The brief itself names the cost of the split - P1 and P2 both derive from the single `refresh` payload, so two pages need either a section filter on the action or a cached payload on the second page - and collapsible blocks reach the stated goal ("an operator looking for one of them scrolls past all of them") with no engine change, no second URL and no duplicated fetch, while also delivering P3's "off the first paint" for journeys. If the operator still wants distinct pages, that remains open and this makes it no harder. P4 (the blocked list moves to Plugin Config with a per-entry disabled flag, a toggle action and corrected SM128 copy) IS NOT BUILT and is now entangled with SM640, which records that Plugin Config should become a line list with per-plugin modals - building P4 in the current inline style would build the thing SM640 asks to be rebuilt. Do P4 as part of, or after, the blocker plugin's move to a modal."
---

# The shape

One page renders every block: visits, depth, entry and exit pages, devices,
search terms, journeys, trails, and the blocked-address list. An operator
looking for one of them scrolls past all of them.

The brief's split is P1-P3 (paginate/restructure plus nav) and P4 (relocate the
blocker to Plugin Config). P4 carries the only engine work: a per-entry
disabled flag and a toggle action, plus truthful copy about what SM128 actually
enforces.
