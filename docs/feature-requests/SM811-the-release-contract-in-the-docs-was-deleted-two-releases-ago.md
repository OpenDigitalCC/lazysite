---
id: SM811
title: "SM811: the release contract in the docs was deleted two releases ago"
subtitle: "CLAUDE.md and rules/release-workflow.md both say the engine agent produces an uncommitted tree and never commits, and both tell the release manager to run ./pre-release.sh. That script was deleted by SM063. SM764 then added tools/handoff.sh, whose FIRST gate fails on an uncommitted tree and whose success line names a branch and a SHA. The written contract and the live gate now require opposite things, and an agent that reads the docs first stops working."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-09
raised-by: engine agent
area: process
---

# The finding

Three documents describe how work leaves this repo, and they disagree.

`CLAUDE.md` (lines 14-27 and 73) and `/srv/projects/rules/release-workflow.md`
both state the **uncommitted-tree contract**:

> Claude produces an **uncommitted working tree** plus a `.release-notes.md` at
> the repo root. Claude **does not** commit, tag, push, or modify git state. The
> user runs `./pre-release.sh` (or equivalent) on their side to rebase Claude's
> edits into a release commit.

`tools/handoff.sh`, which is what actually gates a handover today, opens with
the opposite premise:

    # 1. A clean tree: what is reviewed is what is committed.
    fail "uncommitted changes in the tree"

and reports `READY FOR REVIEW: $BRANCH $SHA`. An uncommitted tree is not a
deliverable to it; it is the first failure.

# How they came apart

Two commits, neither of which touched the documents:

- **`1a7e0478` - "SM063: split release flow into commit.sh + release.sh"**
  deleted `pre-release.sh`. The one command the written contract tells the
  release manager to run has not existed since.
- **`2af5ede0` - "SM764: a branch is handed over gated, a timeout declares what
  it bounds, the coverage gate re-runs alone once"** added `tools/handoff.sh`
  and, with it, the branch-and-SHA review flow the campaign has used ever since.

So this is not a disagreement about which workflow is better. The documented one
was dismantled in stages and its replacement was built, and the prose describing
the old one was left in place - in the two files an agent is most likely to read
before doing anything.

# Why it costs something

It stopped work in this session. Four branches of the 0.13.9/0.13.10 campaign
had already been committed on `claude/*` and offered as READY, which is the flow
`handoff.sh` requires. On reaching the same point with SM685 the agent read
`CLAUDE.md`, found "Claude does **not** commit", and stopped to ask - correctly,
because the two rules cannot both be followed and guessing at a release contract
is not the agent's call. The release manager had to rule on it by hand.

The general shape is the one this codebase files against itself regularly: **a
declaration the code ignores.** Here the declaration is the process document and
the code is `handoff.sh`, but the failure is the same - a statement that reads as
authoritative, is followed by whoever reads it first, and has not been true for
two releases.

# What is asked

1. **Decide which contract is current.** The evidence says the branch flow is:
   it has a gate, the gate is used, and the alternative's entry point is gone.
2. **Rewrite `CLAUDE.md` lines 14-27 and 73** to describe the branch flow -
   commit on `claude/<feature>`, never on `main`, `bash tools/handoff.sh` until
   READY, then offer the branch and SHA.
3. **Rewrite `/srv/projects/rules/release-workflow.md`**, which is shared and
   says it "originated with `lazysite`" - so whatever it claims propagates to
   any project that lists it under `**Applies:**`. Check those projects: a rule
   named for a workflow this repo no longer runs may be wrong for them too, or
   may be right for them and simply misnamed as lazysite's.
4. **Say what became of `.release-notes.md` and `.release-prep.sh`.** Both are
   still specified as per-session deliverables. If the branch and its commit
   message carry that now, the doc should say so; if `.release-prep.sh` is still
   the way commit-side actions are handed over, it should say that too, because
   nothing else does.

# Provenance

Read from the sources in this tree on 2026-09-09: `CLAUDE.md`,
`/srv/projects/rules/release-workflow.md`, `tools/handoff.sh`, the absence of
`pre-release.sh`, and `git log` for the two commits named above. Raised after the
release manager asked why the rules contradicted the practice.
