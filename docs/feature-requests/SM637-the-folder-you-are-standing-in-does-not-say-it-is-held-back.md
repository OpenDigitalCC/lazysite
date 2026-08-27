---
title: "SM637: a padlock on every covered row answers the question from the parent, and says nothing once you have walked in"
subtitle: "Operator, 2026-08-27: 'files - when in protected folder, show at top with padlock'"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED, as part of SM638 rather than on its own commit - recorded here because the filing would otherwise be lost. THE HONEST HISTORY: this was built on a branch that was never landed, and the same feature was then built again as SM638 in a later session. Duplicated effort, caught only when the release contents were checked against the worktrees rather than against my own account of them. WHAT SHIPPED is SM638's version: a banner under the breadcrumb naming what governs the folder the operator is standing in, carrying the controls when the rule belongs to that folder and refusing them when it is inherited - which is SM635's placement rule answered for something that is not on a row. The code from this branch is superseded and is not landed; only the record is."
---

# Where the answer was, and where the operator is

| Standing | The padlock is |
|---|---|
| in the parent, looking at the folder | **on the row** - answered |
| inside the folder, looking at its contents | on the row you just left - **silent** |
