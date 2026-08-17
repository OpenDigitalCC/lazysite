---
title: "SM357 - a guard against committing to the branch a release is cut from"
subtitle: "The contract already said work happens on a claude/<feature> branch that vcs-review lands. Roughly thirty commits went straight onto main in one session and the first anyone saw of them was a release."
brand: plain
status: shipped
status-note: "FILED AND FIXED 2026-08-17 at the release manager's request - \"how do we ensure that you work on branches which I vcs review to main, so I get to see changes?\". The contract was not missing; the moment was. Nothing about committing to main asks anything of you: same command, and the branch you are on is a fact you have to go and look at. This supplies the moment and is deliberately bypassable - the control that actually holds is that main only advances through review, and a hook that cannot be bypassed gets uninstalled rather than obeyed."
---

# What it cost

Two defects found this week were discoverable from a diff and instead cost a
release cycle each: [[SM343]] (a closed day file frozen at the last call made
during that day) and the basis-stamp asymmetry in [[SM338]]. The partner agent
put it plainly: they had been reading versions rather than changes, so every
finding arrived too late to be cheap.

That is what review before a tag buys, and it was unavailable because the work
was never offered as a branch.

# Why a rule was not enough

The rule existed and was written down. It failed because there is no point at
which committing to `main` asks anything of you - it is the same command as
committing anywhere else, and the current branch is a fact you have to go and
check.

A hook supplies the missing moment. It fires at the instant the mistake is made
rather than at review, which is the difference between a comment and a cut.

# What it is, and what it deliberately is not

**It is bypassable.** `--no-verify` defeats it, and so does
`LAZYSITE_ALLOW_COMMIT_ON_MAIN=1`, which the refusal names. That is a choice: a
guard that cannot be got past in an emergency is uninstalled rather than obeyed,
and an uninstalled guard protects nothing.

**The control that actually holds is elsewhere** - `main` only advances through
review. This makes the wrong path loud, not impossible.

**It does not break the workflow it protects.** vcs-review lands a branch onto
main *by rebase*, which commits onto main by definition. A rebase, merge,
cherry-pick or bisect in progress is allowed through. Refusing those would block
the only sanctioned route onto main, which is a guard protecting a branch from
the process allowed to change it.

**The refusal says what to do next.** It prints the `git switch -c` command, and
says that nothing has been committed - the first fear a refusal creates is that
the work is gone, and a refusal that leaves that fear standing gets bypassed on
reflex, which trains the reflex.

**It is committed, not left in `.git/hooks`.** Git does not share hooks through
a clone, so a rule living only there is one each checkout must be told about
separately and forgets silently. `scripts/install-hooks.sh` points
`core.hooksPath` at the tracked directory, which also makes the rule itself
reviewable.

# A fail-open path in the guard, found by its own test

The first version resolved the branch with `git rev-parse --abbrev-ref HEAD`.
That resolves HEAD as a *revision*, so it **fails on a branch with no commits** -
the branch came back empty, matched nothing, and the commit was allowed.

Found because the test harness builds a fresh repository, which is precisely the
case where a guard against committing to main matters least and where the bug
showed most. It uses `git symbolic-ref --short HEAD` now, which reads the ref
HEAD points at without resolving it and therefore answers on an unborn branch.

Worth recording: a guard whose failure mode is *allow* is the defect class this
project has spent the week removing, and it appeared in the guard written to
enforce process.

# Verification

- A commit on `main`, `master` or `integration` is refused.
- A commit on any other branch, including `mainline`, is allowed - a prefix
  match would refuse that one, and refusing a branch nobody asked to protect is
  how a guard gets uninstalled.
- An unborn `main` is still `main`.
- An in-progress rebase, merge, cherry-pick or bisect commits onto main without
  complaint.
- The override works and is named in the refusal.
- The refusal says how to move the work and that nothing was lost.

# Related

[[SM325]] (tag after the branch lands - the same workflow seen from the release
end), [[SM354]] (changelog refs stale after a rebase, the same rebase seen from
the documentation end), and the vcs-review contract itself.
