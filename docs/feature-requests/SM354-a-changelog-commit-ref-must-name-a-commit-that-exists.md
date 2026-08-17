---
title: "SM354 - seventeen changelog entries cited commits that no branch contained"
subtitle: "Seven of them cited commits that did not exist at all. The convention makes the commit ref the thing that marks an item as built rather than merely written down, so the evidence for `this shipped` had evaporated in the one place a reader is told to look."
brand: plain
status: shipped
status-note: "FILED AND FIXED 2026-08-17, found immediately after vcs-review landed a branch and the refs I had written into the changelog stopped resolving. Audited all 128: 17 were wrong. The cause is structural rather than careless - work happens on a claude/<feature> branch and vcs-review lands it BY REBASE, so any ref written before landing is stale afterwards. [[SM325]] recorded exactly this for TAGS after 0.10.10 was cut twice, fixed the tag half, and nobody looked at the changelog - where the same rebase had left seven refs pointing at objects that no longer exist. All 17 re-resolved by matching commit subjects on main, and t/lint/53 now fails on any that cannot be followed."
---

# What was wrong

The changelog's own preamble makes the ref load-bearing:

> An item that SHIPPED in a release begins its own bullet and **names the commit
> that implemented it**. The commit ref is what marks it as built rather than
> merely written down.

Audited across 128 refs:

```datatable
columns: Condition | Count | What it means
widths: 5cm | 1.8cm | X
bold: 1
tone: medium
---
Resolves, on a branch | 111 | correct
On no branch | 10 | survives in the reflog; unreachable from any history, and collected eventually
**Does not exist at all** | **7** | the evidence is already gone
---
```

All seven of the missing ones are in the 0.10.10 entry - SM313 through SM320.

# Why it drifts, and why care will not prevent it

Work is done on a `claude/<feature>` branch. `vcs-review` lands it onto main **by
rebase**, which gives every commit a new SHA. A ref written into the changelog
while the branch is still a branch is stale the moment it lands.

The old object survives in the reflog for a while - long enough for a spot check
to pass, and short enough to be gone when somebody actually needs it. So the
window in which the mistake is detectable by looking is exactly the window in
which it does not yet matter.

**[[SM325]] already worked this out, for tags.** After 0.10.10 was cut twice it
concluded: *tag AFTER the branch lands, not before*. The same rebase, on the same
day, invalidated seven changelog refs in the release it was about, and that half
went unexamined because the tag was the thing that had visibly broken.

# The rule

Write the commit ref **after** the branch lands, not before. Same rule as the
tag, same reason, and now the same kind of check.

# It happened again immediately, to this filing

SM354 landed on main by rebase. Its own changelog entry named `d7da8d4` - the
pre-rebase SHA - and the landed commit is `274be4b`. So **main went red on
`t/lint/53` the moment this shipped**, caught by the check this filing added,
against the entry this filing wrote.

That is the strongest available demonstration that the check works, and it
settles the remedy. "Write the ref after the branch lands" is not advice that
can be followed while writing a branch: the SHA does not exist yet, and any
value put there is wrong by the time anybody reads it.

So the convention is now explicit in the changelog's own preamble:

**While the work is on a branch, write `(PENDING)`. Once it is on `main`,
replace it with the landed SHA.**

`t/lint/53` ignores `(PENDING)` - it only matches hex - so the placeholder is
safe and a stale ref is not. The filling-in is a small deliberate step after
landing, which is the only point at which the answer exists.

# The fix

All 17 re-resolved by matching commit subjects against main, and
`t/lint/53-changelog-commit-refs-exist.t` fails on:

- a ref naming a commit that does not exist, and
- a ref naming a commit that exists but no branch contains.

The second is the one worth having. A commit reachable only from the reflog
looks fine to `git show` today and is gone next month, which is precisely how
seven of these got as far as a shipped release.

The lint **skips loudly** outside a git checkout - a tarball has no repository
and cannot resolve anything - rather than passing on having checked nothing,
which would be this project's own recurring defect written into the test that
guards against it.

# The other half: the changelog conflicted with itself

Found while rebasing four branches that had all been refused review on the same
day. Each added a bullet to the same `## Unreleased` block, so each collided
with the others - and the collision is **spurious**: both additions are wanted
and neither touches the other's text.

Worse, the obvious resolution is wrong. "Keep both sides" duplicates every
historical entry whose commit ref was re-spelled by the landing rebase, because
the branch carries the pre-review SHA and main carries the landed one. So the
naive fix to a conflict caused by this filing's defect reintroduces this
filing's defect, doubled.

`.gitattributes` now marks `CHANGELOG.md merge=union`, which keeps both sides of
a conflicting hunk. That is the correct semantics for a file only ever appended
to in different places. It does not make the file conflict-free in general - two
branches editing the SAME entry still conflict, and should - it removes the case
where they are merely both adding.

# Verification

- Every commit ref in the changelog resolves.
- Every commit ref is contained by at least one branch.
- The check fails on the changelog as shipped in 0.10.12 (17 bad refs) and
  passes on the corrected one.
- Outside a git checkout the check skips with a reason rather than passing.
- Two branches each adding an Unreleased bullet merge without a conflict, and
  without duplicating anything already on main.

# Related

[[SM325]] (the same rebase, the same lesson, applied to tags - and the half that
was fixed), [[SM258]] (backlog status and changelog agreeing), and
`t/lint/26-backlog-status-matches-changelog.t`, which checks that the changelog
and the filings agree about WHAT shipped while this checks that the evidence it
cites can still be followed.
