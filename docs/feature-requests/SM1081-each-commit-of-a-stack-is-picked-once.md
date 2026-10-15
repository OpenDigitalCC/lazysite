---
id: SM1081
title: "SM1081: each commit of a stack is cherry-picked once"
subtitle: "The overnight run picks each branch's own commits only - from the branch below it to its tip - so a pick whose patch-id moved on main is not offered again for every branch above it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-15
raised-by: coordinating session, 2026-10-15
area: release
status-note: "SHIPPED (PENDING) on n591: tools/integration.pl picks <previous branch tip>..<branch tip> per branch (the lowest from main), with git cherry's patch-id check limited to that range. t/tools/166."
---

# What happened

On 2026-10-15 (`tmp/overnight/integration-2026-10-15.log`) the run picked
n566's one commit three times - once per branch of the stack n566 < n567 <
n568 - and the third copy collided in `starter/docs/forms.md`, so the stack was
reported `CONFLICT with main` though main touched none of its files. The same
happened to n580 and n584.

# Cause

Since SM1080 each branch of a stack is picked in turn, but the pick for every
branch took `git cherry HEAD <branch>` - everything on the branch not on the
integration tree, which includes the lower branches' commits. `git cherry`
compares patch-ids, and the first pick of n566's commit had **auto-merged**
(`Auto-merging CHANGELOG.md`: main had moved its context), so the copy on the
integration tree carried a new patch-id. The original was therefore not seen
as applied, was picked again for n567 (auto-merging again) and again for n568,
where the third copy of the same insertion collided with the first two.

# What changed

- Each branch picks only its own commits: `<tip of the branch below>..<its tip>`,
  the lowest from main (the same commits as from the stack's base). `git cherry HEAD
  <tip> <from>` keeps the patch-id check against the integration tree over that
  range, which is what still skips a commit landed in part.
- The whole-stack pick used by the red-night attribution takes the same range,
  `main..<stack tip>`.

t/tools/166: a three-branch stack on an older main whose pick auto-merges (main
changed a line inside the pick's context but not adjacent to it); with the old
code it reports `CONFLICT with main`, now each commit is on the tree once and
every branch is READY.
