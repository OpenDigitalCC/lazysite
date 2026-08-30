---
title: "SM638: the protection controls exist only on the row above, so an operator who has walked INTO a protected folder cannot act on it from where they are standing"
subtitle: "Operator, 2026-08-27: 'when in the folder, the controls from the expansion panel should also be available'. Recorded, not built"
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT. A banner under the breadcrumb says what governs the folder the operator is standing in, and carries its controls when the rule belongs to that folder. THE PLACEMENT QUESTION THE FILING SAID HAD TO BE ANSWERED FIRST is answered rather than sidestepped: SM635 put Remove-protection only on the row that OWNS the rule so a button never acts somewhere other than where it appears, and a banner is not on a row - so it names the path it acts on, in the label and in the confirmation, and offers controls ONLY for this folder's own rule. An INHERITED rule gets no control at all; it says which ancestor carries it and links there, because removing it from here would act somewhere else, which is exactly the defect the placement rule prevents. A site-wide rule says plainly that it is not this folder's. IT REUSES protectionFor(), the listing's own resolver, so the banner and the padlocks cannot disagree about what governs a path - a second resolver would be two answers to one question. Cleared when the sections load FAILS, because a stale banner about protection is worse than none. Asserted in t/lint/72, SM635's own contract test, rather than a competing file: the placement rule belongs there. Two sabotages, both fail - giving an inherited rule a control fails 2."
---

# Where the controls are, and where the operator is

| | |
|---|---|
| The controls | on the folder's row, visible from its **parent** |
| The operator | inside the folder, looking at its contents |

# The question to answer before building it

SM635 put Remove-protection only on the row that owns the rule, so a button
never acts somewhere other than where it appears. A control at the top of a
listing is on no row - so it needs its own answer to that question, not the
same control moved.
