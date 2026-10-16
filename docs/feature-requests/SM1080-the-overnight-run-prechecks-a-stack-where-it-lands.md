---
id: SM1080
title: "SM1080: the overnight run prechecks a stack where it lands"
subtitle: "The precheck runs on the integration tree after the stack is cherry-picked, so a stack based on an older main is not failed for what main has since fixed."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-14
raised-by: coordinating session, 2026-10-14
area: release
status-note: "SHIPPED (0.15.5) on n587: tools/integration.pl cherry-picks each branch of a stack onto the integration tree, then runs the precheck there against the tree before it; a failure rebuilds the tree without the stack; the results record each stack's base and how far behind main it is. t/tools/151-153."
---

# What happened

SM1062's overnight integration run prechecked each stack on the stack's OWN
tree, against main. On 2026-10-14 three stacks (n568, n575, n584) were based on
`e63e1fe2`. They failed Odoo tests that main's n585 (`1266d468`) had since
fixed, and were reported NOT READY (`tmp/overnight/results-2026-10-14.txt`,
`precheck-2026-10-14-n575.log`, `-n568.log`, `-n584.log`). Each would have
landed green: the whole suite is run on the integration tree, where main's
fixes are present, and the precheck was the one check that was not.

# What changed

- Each stack's commits are cherry-picked onto the integration tree first -
  branch by branch, lowest first, with the same order and conflict rules - and
  `tools/precheck.sh` then runs there with the branch's commits as the diff
  against the tree before them (the mangled-literal check reads the same diff).
- A conflict is still reported as `CONFLICT with <earlier stack>: files`. A
  precheck failure still leaves the stack out, NOT READY, with the failing
  branch named and the rest of the stack "stops at"; the tree is reset to what
  it was before the stack, so the later stacks and the suite never see it.
- The results file says where each stack was based: `BASE: <tip> sits on <sha>;
  stack base is older than main by N commits - its commits are cherry-picked
  onto the integration tree and prechecked there`, or `sits on main <sha>` when
  it is current, so a reader sees why a stack was rebased in the run.

# Tests

t/tools/151 (a stack on an old main whose fault main has fixed: NOT READY
before, READY after; a stack carrying the fault is left out and the tree
rebuilt; a conflict still reported), 152 (the base lines), 153 (a stacked
branch prechecked against the tree before it, an upper failure leaves the whole
stack out).
