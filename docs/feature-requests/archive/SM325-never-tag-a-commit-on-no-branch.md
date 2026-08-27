---
title: "SM325 - release.sh refuses to tag a commit on no branch"
subtitle: "0.10.10 was cut twice: the first tag named a branch tip, vcs-review then landed that branch with new SHAs, and the tag was left naming a commit no branch contained"
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.11. release.sh checks `git branch --contains` before tagging and refuses, with the lesson in the message - tag AFTER the branch lands, not before. It warns rather than refuses under --no-fetch, because a build host with no remote may legitimately have an incomplete branch set. Verified against the real commits: the guard fires on 98be8b97, the first cut's target, and stays quiet on a normal HEAD. FILED 2026-08-16."
---

# What happened

`v0.10.10` was tagged on the tip of `claude/sm305-principal-picker-and-polish`.
vcs-review then landed that branch onto `main` by rebasing, so every commit got a
new SHA, and the tag was left pointing at a commit that `git branch --contains`
matched nothing for.

Nothing had been pushed, so the cost was a delete and a re-cut - which is a full
gate run, roughly an hour, to fix something `--contains` answers in a second.

# Why it matters beyond tidiness

**A tag on no branch is a release whose provenance cannot be followed from any
branch history.** Someone auditing later runs `--contains`, gets nothing, and has
to work out whether that is a problem.

If the tag were ever deleted the commit becomes unreachable, so the artefact's
source would exist only in whatever tarball happened to be kept.

The content was not at risk here - the shipped tree differed from `main` only by
three filings excluded from the manifest, so the installed product was identical.
That was luck rather than design, and it is not the property to rely on.

# The rule this encodes

**Tag after the branch lands, not before.** Where a branch goes through review
that may rebase it, the tag belongs on the landed commit.

The guard warns rather than refuses under `--no-fetch`, because a build host with
no remote credentials may legitimately have an incomplete set of branches and
should not be blocked by that.

# Related

SM303 (the same tool conflating two jobs for two parties), and the vcs-review
workflow that rebases a branch on landing.
