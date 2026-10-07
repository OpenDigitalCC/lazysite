---
id: SM944
title: "SM944: Split the processor and the manager API into modules by area"
subtitle: "lazysite-processor.pl is 10,378 lines and lazysite-manager-api.pl 5,247; reading any part costs navigating the whole."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: processor
status-note: "Filed 2026-10-07 at the release manager's direction, from the development-cost analysis. Size L. Planned in WORK-PLAN-0153 group E."
---

# Measured

The two largest files are where most fixes land, and every read of either is expensive: 10,378 and 5,247 lines, 38% and 36% comments. `Handlers.pm` and `Manager/*` show the pattern already works - logic in modules, the CGI a thin dispatcher.

# Proposal

Move each area (render pipeline, includes, feeds, cache, auth gate; and the remaining inline manager actions) into its own module with a short index header. One area per branch, behaviour-preserving, each landing with the suite unchanged.

# Done when

Neither script holds logic an area module could; each module starts with an index of what it holds. No behaviour change, proven by the existing suite at every step.
