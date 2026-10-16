---
id: SM1087
title: "SM1087: a stack whose branch name has a slash is prechecked"
subtitle: "The integration run names its precheck log from a flattened branch name, so a claude/... branch is prechecked instead of reported failed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: lazysite developer agent, 2026-10-16
area: release
status-note: "SHIPPED on n600: tools/integration.pl precheck_branch; t/tools/167."
---

# What happened

The on-demand integration run of 2026-10-16 queued
`claude/n599-an-operator-may-add-an-operator`. `precheck_branch` named the log
`precheck-DATE-<tip>.log` from the branch name as-is. The slash made that a
path into a directory that did not exist, the shell could not open the log,
and the run reported:

    NOT READY: claude/n598-... - precheck failed on the integration tree

No precheck had run. The run integrated nothing and fell back to the plain
suite on main.

# What shipped

The tip is flattened for the file name only (anything outside
`A-Za-z0-9._-` becomes `-`). t/tools/167 queues a `claude/s1` stack through
the overnight rig and checks that it is prechecked and READY.
