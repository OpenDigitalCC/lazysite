---
id: SM1062
title: "SM1062: the overnight run tests what is about to land, before it lands"
subtitle: "The queued stacks are cherry-picked onto main in queue order on their own branch, one whole suite runs there, and the verdict says which to land, in which order - or which stack, or which pair, broke it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: release manager, 2026-10-12
area: release
status-note: "SHIPPED (PENDING) on n552: tools/integration.pl (run by tools/overnight.sh) releases the queued worktrees, prechecks each stack, cherry-picks them onto main in queue order as review/assess/integration, runs one suite (tools/suite.sh --tree), and prints LAND IN THIS ORDER or a red verdict naming main, a stack or a clash. t/tools/145-149."
---

# The ruling

SM1061 moved the whole suite out of the handoff, and queued the heavy handoffs
overnight, each run on its own stack. The release manager then asked:

> "maybe the suite runs on its own branch, not main, then the review process
> checks that in to main"

The coordinating session agreed and recommended the design below, which this
builds. A stack tested alone is not what lands: the one cross-stack clash on
2026-10-12 (`t/unit/processor/101`) passed on each branch and failed on main.
Testing the queue together, in the order it will land, finds that before the
landing instead of after it.

# What was built

The integration run
: `tools/integration.pl`, run by `tools/overnight.sh` at 00:30 with the night's
  queue, at nice 19 and idle I/O. In order:

  1. **Release.** Every queued worktree, and any worktree holding a branch of a
     queued stack, is detached at main (the main checkout returns to main), so
     vcs-review - which does not offer a checked-out branch - can offer them.
     A worktree with uncommitted changes is left as it is, and its stack is NOT
     READY: what is reviewed is what is committed.
  2. **Precheck** each stack as `tools/handoff.sh --stack main` does (since
     SM1080, on the integration tree after its commits are picked, not on its
     own branch tree): each
     branch, lowest first, against the one below it, with the mangled-literal
     check. A failure leaves the stack out, NOT READY, before anything is built.
  3. **Build** the integration tree in `tmp/wt-integration`, a detached
     worktree, fresh from main every night: for each stack in queue order, the
     commits `git cherry` says are not yet applied are cherry-picked onto main
     and the stacks before it. The tip is kept as `review/assess/integration`.
  4. **One whole suite** on that tip: `tools/suite.sh --tree`, through the
     host-wide suite lock, inside the 5 h the whole run keeps to.
  5. **The verdict** in `tmp/overnight/results-DATE.txt`, and an inbox report
     on a red night or a conflict.

The branch name
: vcs-review's `discover_branches` skips `review/staging/` and
  `review/assess/`; `review/integration` it would offer for review. So the tip
  is `review/assess/integration`. vcs-review's own assess branch is
  `review/assess/<repository name>` (`review/assess/lazysite` here), so the two
  never meet.

Cherry-pick, not merge
: vcs-review lands a branch by cherry-picking its commits onto main. Picking
  each stack's commits onto main in queue order is the same operation, so
  "landing in this order makes main equal this tree" holds by construction; a
  merge would test a tree no landing produces. It also handles a stack landed
  in part the way vcs-review does: `git cherry` against the tree so far marks a
  commit already on main (or already picked from an earlier stack tonight) as
  applied, and it is skipped.

A conflict
: A stack that does not apply on top of the ones before it is reported
  `CONFLICT with <earlier stack>: <stack> left out - <files>`, naming each
  earlier stack that touched a conflicting file, or `main` when none did. It is
  NOT READY, and the rest of the queue continues.

The verdict
: GREEN prints `LAND IN THIS ORDER:`, the stack tips with SHAs and their
  branches, then a `READY FOR REVIEW: BRANCH SHA (precheck passed; suite passed
  on review/assess/integration SHA)` line per branch - the shape
  `tools/handoff.sh` prints. A green night files nothing in the inbox.

Attribution on a red night
: Each failing test file is run again on its own: on the integration tip (a
  file that passes there is reported "not reproduced", and puts no stack out),
  on main, on each stack applied alone on main, and - when no single stack
  fails it - on each pair, in queue order. The cause is `main itself`, `stack
  X`, or `stacks X+Y together (clash)`; when no pair reproduces it, every stack
  together. Only the stacks a cause names are NOT READY, with the failing files;
  the others are READY and say they were not implicated. A red night files
  `DATE-overnight-integration-red.md` in the inbox; a conflict on a green night
  files `...-green.md`.

An empty queue
: Nothing queued, or every stack left out: the plain nightly runs instead
  (`tools/suite.sh --nightly` on main), so main is checked every night. With a
  queue, the integration tree is main plus the stacks, so the suite on it
  checks main too.

The limits
: The runner lock and its skip are unchanged. A whole-suite run already holding
  the suite lock is a skip, never a wait: the stacks go back on the queue for
  the next night. The suite and the attribution keep to
  `$LAZYSITE_NIGHTLY_LIMIT` (5 h) from the start of the run; a file the run has
  no time left to attribute puts every stack out, and says why.

The queue interface
: Unchanged: `tools/overnight.sh --queue WORKTREE TIP [--full|--release]`. The
  flag is still accepted and changes nothing: every stack gets the whole suite,
  and the bench is the release gate's.

The handoff
: `tools/handoff.sh` keeps its daytime role: a precheck-only check an agent can
  run before queueing. The READY a stack is offered with now comes from the
  overnight integration run.

# What was left alone

- The generators (`tools/regen-generated.sh`) are not run overnight: the
  handoff commits what they regenerate onto the author's branch, and an
  unattended run should not write to a branch it is about to report on. A
  stale generated document still fails the tests that check it (t/lint/110 in
  the precheck, t/tools/25 and 26 in the suite; SM948), and its author runs
  `tools/regen-generated.sh` (or `tools/handoff.sh`) by day.
- The tracked-tree check (`tools/tracked-tree-check.pl`) is not run on the
  integration tree; the plain nightly never ran it either.
