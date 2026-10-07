---
id: SM945
title: "SM945: Comments state the invariant and the reason; history lives in git and the filing"
subtitle: "30,069 of 91,692 code lines (33%) are comments, much of it incident narrative read on every visit."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-07
raised-by: release manager, from the development-cost analysis on WORK-PLAN-0153 (2026-10-07)
area: docs
status-note: "Filed 2026-10-07 at the release manager's direction, from the development-cost analysis. Size M. Planned in WORK-PLAN-0153 group E."
---

# Measured

Comment density is 33% across lib, tools, plugins and the CGIs (release.sh 44%, ControlApi/Actions.pm 46%). Much of it is history - which SM, what broke, who measured what - which git log and the filing already hold. It is read, and paid for, every time the file is opened.

# Proposal

A comment says what must stay true and why, in about three lines, naming the SM for the history. Applied to a file when it is next touched, not as a sweep; a lint may flag a single comment block over ~12 lines on changed lines only.

# Done when

New and touched code follows the rule; the density figure falls release on release.
