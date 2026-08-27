---
title: "SM638: the protection controls exist only on the row above, so an operator who has walked INTO a protected folder cannot act on it from where they are standing"
subtitle: "Operator, 2026-08-27: 'when in the folder, the controls from the expansion panel should also be available'. Recorded, not built"
brand: plain
standard-margins: true
status: candidate
status-note: "RECORDED AT THE OPERATOR'S REQUEST 2026-08-27, explicitly not built - filed so it is not lost between sessions. SM635 put the protection into the LISTING: a padlock beside the access rights on any covered row, and an expansion carrying the rule, who may read it, and the Publish / Remove-protection controls - the latter on the row that OWNS the rule, since an inherited one cannot be changed from the row it covers. THE GAP THAT LEAVES: those controls live on the folder's row, which is visible from its PARENT. An operator who has clicked into the folder is now looking at its contents, and the row carrying the controls is on the screen they just left. They must navigate up to change the protection of the folder they are standing in - and 'up' is exactly where they will lose their place. THE ASK: when the current folder is itself protected, the same controls should be reachable without leaving it. WHAT NEEDS DECIDING FIRST, and why this is a filing rather than a patch: SM635 deliberately put Remove-protection ONLY on the owning row, so that a button never acts somewhere other than where it appears. A control at the top of a listing is not on a row at all, so it needs its own answer to the same question - it should act on THIS folder and say so in its label, rather than being the same control relocated. Getting that wrong reintroduces the defect SM635's placement rule exists to prevent. RELATED: the top-of-listing padlock (SM637) is the READ half of the same idea and ships first; this is the WRITE half and deserves the extra thought."
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
