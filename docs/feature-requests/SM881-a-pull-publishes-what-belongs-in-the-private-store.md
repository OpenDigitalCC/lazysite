---
id: SM881
title: "SM881: a git-sync pull publishes a file that belongs in a protected folder"
subtitle: "SM852's S6, split out because it is not the same kind of problem as its siblings. Every other row was fixed by resolving BEFORE the write; this one cannot be, because the write belongs to git. The obvious sweep afterwards is RULED OUT - resolve_for_write cannot answer the question once a merge has run, and this filing records why so the next attempt does not rediscover it."
brand: plain
standard-margins: true
status: candidate
status-note: "DEFERRED 2026-09-14 by the release manager - 'needs some thought, file and defer to further discussion and decision'. Split out of SM852 (S6), where it was graded from reading. The exposure is real: git merge writes the worktree, the worktree is the docroot, so a remote commit adding a file under a protected folder publishes it and the operator's only signal is that the pull succeeded. THE POST-MERGE SWEEP IS RULED OUT, demonstrated not assumed: I wrote it, and resolve_for_write answers PUBLIC for the pulled file - correctly, by its own documented rule that an ancestor existing in the docroot settles it, and git has just created that ancestor. The private-store resolver therefore cannot decide gatedness after a merge; the evidence it reads has been overwritten by the thing being corrected. Deciding it properly means asking the ACL STORE, which is what actually makes a folder protected - a new access-semantics dependency inside a plugin, and a second answer to 'is this path gated?' beside the resolver, which is the shape SM836 and SM268 02-5 both exist to remove."
---

# What happens

`git merge` writes into the worktree, and the worktree is the docroot. A remote
commit that adds a file under a protected folder therefore lands it in the
served tree. The pull reports success; nothing says the file is now public.

This is correct behaviour for git. It is not something the plugin can change by
asking git to write somewhere else.

# Why its siblings' fix does not apply

Every other SM852 row was closed the same way: resolve where the file belongs
**before** writing it, through `Lazysite::Private::resolve_for_write`. That is
not available here, because the write is git's and happens first.

So the natural shape is a sweep **after** the merge — `_after_apply` already
runs with the list of changed files, which looks like the perfect seam.

# The sweep does not work, and this is the part worth keeping

I wrote it and measured it. For a file git has just added under a gated folder,
`resolve_for_write` answers **public**.

That answer is correct. The resolver's own documented rule is that an ancestor
existing in the docroot settles a path as public, checked first — and it explains
why, at length: a bare container in the private store is not evidence that a
folder is gated, and treating it as such once caused new public content to be
silently unpublished.

The merge has **created that public ancestor**. So by the time the sweep runs,
the evidence the resolver reads has already been overwritten by the very thing
the sweep exists to correct.

**The private-store resolver cannot answer this question after a merge.** Any
future attempt that starts there will produce a sweep that passes its tests,
looks right in review, and moves no files.

# What a real fix needs, and the cost

Gatedness is a property of the **ACL store** — that is what makes a folder
protected. A working sweep has to ask it directly.

That means a plugin holding an opinion about permissions, and a second answer to
"is this path gated?" living beside the resolver. SM836 exists because write
paths each resolved for themselves; SM268 02-5 was two walkers disagreeing about
one question. This would add a third reader of access semantics in the place
furthest from where they are enforced.

That may still be the right trade — an exposure is worse than a duplicated
reader — but it is a decision about where access semantics may live, not a
patch, and it is the release manager's.

# Not attempted

- **Refusing the pull** when a changed path is gated. Plausible, and it turns a
  silent exposure into a stuck sync; wants the same ACL-store read to decide,
  so it does not avoid the question.
- **Warning after the fact.** Cheap, and it leaves the file public.

# Related

[[SM852]] (this was its S6), [[SM836]], [[SM286]].
