---
id: SM829
title: "SM829: the release mistakes are state errors, not knowledge errors"
subtitle: "Nine slips in one day around the release path, catalogued. Only two came from not knowing a rule; the rest came from not checking the RESULT of a step before taking the next one - and several happened with the rewritten contract open in the same session that wrote it. So the answer is not a better runbook. It is a toolchain that can answer 'where am I, and is it safe to start?' in one command, and that makes the offer atomic with the gate that earns it."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-10
raised-by: release manager
area: process
---

# The catalogue

Every release-path slip from 2026-09-10, with what caused it. This is the
evidence the recommendation rests on, and it is deliberately unflattering.

| # | What happened | Cause |
| --- | --- | --- |
| 1 | Committed on `main` | Did `git checkout main` after a handoff, then started new work without branching |
| 2 | Reported a commit that never happened | Chained `commit && handoff`, read the handoff's output |
| 3 | Announced READY while the branch was still checked out | Reported from the gate's result; skipped the step after it |
| 4 | Branched from `main` while four of my own commits sat unlanded elsewhere | Never looked |
| 5 | Hand-edited a generated file | Did not read the "do not edit by hand" line in the file's own body |
| 6 | Left a `(PENDING)` ref that had landed | Lint 65 caught it; my rehearsal had run only lints 26 and 53 |
| 7 | `status: partial` with a note saying NOT BUILT; `status: candidate` with a shipped step | Updated one and not the other |
| 8 | Baseline written on `main` | A branch-from-a-deleted-branch failed and I did not read the failure |
| 9 | Committed over a failing lint | Chained `lint && commit` |

**Two of those are knowledge errors** - 5 and 6, where I did not know a fact
about a file or a gate. **The other seven are state errors**: I knew the rule and
did not check where I was, or did not read what a command returned before acting
on it.

**The sharpest evidence that a runbook is not the gap**: item 3 broke the exact
sequence I had written into `CLAUDE.md` that morning - *handoff until READY, THEN
`git checkout main`, then offer the branch and SHA* - in the same session, having
authored the sentence.

# What would actually have prevented them

## 1. One command that answers "where am I, and is it safe to start?"

Items 1, 3, 4 and 8 are all the same failure: acting without knowing the repo's
state. A single `tools/where.sh` printing:

- current branch, and whether the tree is dirty;
- commits ahead of `main`, and whether HEAD matches the last handoff SHA;
- **every other `claude/*` branch ahead of `main`** - which is item 4 exactly;
- whether the branch is held by another worktree.

Four of nine, from one command run before starting.

## 2. Make the offer atomic with the gate

`tools/handoff.sh` says READY and then a human is supposed to do two more things:
`git checkout main`, and tell the release manager. Item 3 is the gap between
them, and the reviewer's tooling caught it - *"checked out at
/srv/projects/lazysite (in use): not offered"* - which means the gap is real
enough that the other side has to defend against it.

**On success, handoff should release the branch itself** and print the offer line
as one act. Then READY and offered are the same event rather than two, and there
is no step to forget.

## 3. Remove the things worth chaining

Items 2 and 9 are both `A && B` where B's output hid A's result. A
`tools/commit.sh` that commits, re-reads `git log -1`, and prints what actually
landed leaves nothing to chain - and would have made item 2 impossible, since the
hook's refusal would have been the output.

This is the same principle the codebase already applies to loaders: **report what
happened, not what was attempted.**

## 4. A guard for generated files

Item 5: `docs/reference/control-api-actions.md` carries "Generated file - do not
edit by hand" in its own first paragraph, and I edited it anyway. A pre-commit
check refusing a commit that touches a file whose head says that would catch it
before the suite does, and it is a five-line hook.

## 5. What does NOT need building

**The gates are working.** Nine slips, and the gates caught seven of them -
lint 09 twice, lint 65, lint 121, lint 26's status rule, perlcritic, the
generated-file test, and the pre-commit hook. Two reached the release manager.
That is a defensible ratio and the argument for more gates is weak; the argument
is for making the *state* legible so fewer are needed.

**And the runbook is now correct.** [[SM811]] fixed it this morning. Adding
detail to a document that was already accurate at the moment it was disobeyed
would be treating the symptom.

# Recommendation

Build 1 and 2; they are small and they cover six of the nine. Build 3 if the
chaining recurs after 1 and 2. Build 4 opportunistically - it is a hook and a
grep.

**Do not write a longer runbook.** The failures were not caused by missing
instructions, and a longer document is a thing to skim rather than a thing to
check against.

# Provenance

Asked by the release manager on 2026-09-10: "How to make less mistakes around
release? is a better runbook required? does the toolchain need to be clearer?"
The catalogue is from this session's own record.
