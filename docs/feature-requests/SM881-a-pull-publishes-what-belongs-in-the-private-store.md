---
id: SM881
title: "SM881: a git-sync pull publishes a file that belongs in a protected folder"
subtitle: "SM852's S6, split out because it is not the same kind of problem as its siblings. Every other row was fixed by resolving BEFORE the write; this one cannot be, because the write belongs to git. The obvious sweep afterwards is RULED OUT - resolve_for_write cannot answer the question once a merge has run, and this filing records why so the next attempt does not rediscover it."
brand: plain
standard-margins: true
status: candidate
status-note: "RULED 2026-09-14 by the release manager: the ACL read becomes ONE ENGINE ANSWER, a supported resolver that plugins call - NOT a private read inside git-sync. git-sync asks it after a merge and relocates what git published. See 'The ruling' below. Previously DEFERRED 2026-09-14 - 'needs some thought, file and defer to further discussion and decision'. Split out of SM852 (S6), where it was graded from reading. The exposure is real: git merge writes the worktree, the worktree is the docroot, so a remote commit adding a file under a protected folder publishes it and the operator's only signal is that the pull succeeded. THE POST-MERGE SWEEP IS RULED OUT, demonstrated not assumed: I wrote it, and resolve_for_write answers PUBLIC for the pulled file - correctly, by its own documented rule that an ancestor existing in the docroot settles it, and git has just created that ancestor. The private-store resolver therefore cannot decide gatedness after a merge; the evidence it reads has been overwritten by the thing being corrected. Deciding it properly means asking the ACL STORE, which is what actually makes a folder protected - a new access-semantics dependency inside a plugin, and a second answer to 'is this path gated?' beside the resolver, which is the shape SM836 and SM268 02-5 both exist to remove."
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

# The ruling

**2026-09-14, the release manager: the ACL read lives in the ENGINE, as one
supported answer that plugins call.** Not a private read inside `git-sync`.

This refuses the cheaper option on exactly the grounds the section above
raised. The trade was never "an exposure versus a duplicated reader" — it was
"who owns the question", and the answer is the same one [[SM836]] gave for gated
writes: **one owner, everything else asks.** A second reader of access semantics
was the thing to avoid, and paying for the resolver avoids it permanently
instead of for one plugin.

So the shape is:

- **The engine gains an ACL-aware resolver.** Given a path, it answers whether
  that path is gated, by reading what actually makes a folder protected — the
  ACL store — rather than by inferring it from what exists in the docroot.
- **`git-sync` calls it after a merge** and relocates what git published.
- **The next plugin with the same need asks it** rather than inventing its own.

## This is not a second `resolve_for_write`

Worth being exact, because the names will invite the confusion. The existing
resolver answers *"where should I write this?"* from docroot evidence, and the
whole finding above is that that evidence is destroyed by a merge. The new one
answers *"is this path gated?"* from the ACL store, which a merge does not
touch. Different question, different evidence, and the reason there are two is
written down here rather than left for someone to rediscover and "simplify".

Whether `resolve_for_write` should end up *asking* the new resolver — which
would make it one reader again rather than two — is a real question, and it is a
design question for the work, not something to assume in either direction.

## The resolver is cheaper than this filing implied — and it is a promotion

Written before the code was mapped, this filing reads as though the engine needs
a new access-semantics subsystem. It does not. Most of it exists:

- **`Lazysite::Auth::Acl::_acl_entry_for`** (`lib/Lazysite/Auth/Acl.pm:319`)
  already answers *"which rule governs this path?"* with the full precedence —
  exact key, then the `.md`/`.url`/`.html` stem, then the **longest ancestor
  prefix**, then the site-wide key. That last one is the whole question SM852
  asks. It is simply not exported: `@EXPORT_OK` at `Acl.pm:21-22` lists nine
  names and this is not among them. Verified by reading the list.
- **A path predicate already exists too** — `_acl_governed`
  (`lazysite-processor.pl:994`), which takes an absolute path, maps it to a
  content-relative key and asks exactly that question. It is script-local: not a
  module, not exported, unreachable from a plugin.

So the ruled work is largely **promoting an existing private answer into a
supported one**, not designing a new one. That should make it markedly smaller
than the cost this filing argued — and it is worth saying plainly, because a
filing that overstates its own price is how good work gets deferred twice.

## One answer does NOT mean deleting the deliberate twins

`lazysite-processor.pl` re-implements the ACL reader on purpose and `t/lint/31`
pins the twin; `tools/lazysite-check.pl` avoids the library too, deliberately, so
it runs where the library is not installed. Those are not the duplication this
ruling is about.

"One engine answer, callable by plugins" means one answer **for the library's
consumers** — plugins and the Manager modules. The pinned twins stay, for the
reasons they were written. Recording this here because the next reader who takes
"one answer" literally will go and delete them, and a lint will be in the way for
a reason they will then be tempted to overrule.

## The trap: fail-closed is safe for a READ and destructive for a MOVE

`_acl_governed` returns **1** when the ACL store will not load
(`lazysite-processor.pl:1009` — "counts as governing everything"). That is
correct for its job: if we cannot tell, refuse to serve.

The sweep this filing asks for **inverts the consequence**. Same convention, same
value, and a store that fails to load now means *relocate every changed file into
the private store* — an unreadable config silently unpublishing a site's content
on the next pull. That is worse than the exposure being fixed.

So the new resolver must distinguish **"not gated"** from **"could not tell"**,
and git-sync must treat the second as *stop and report*, not as either answer.
Two states, not a boolean, and the reason is written down here so it survives the
first person who finds the tri-state fussy.

## It pays for [[SM882]] too

Ruled the same day: a fully gated content root is supported and must contain
nothing public. Both *"is this root fully gated?"* and *"may this asset go
here?"* are questions for this resolver. The two filings are one piece of work,
and neither should be built without the other in view.

## Reproduce first

Graded from reading, like its siblings. The exposure is sharply argued and the
post-merge sweep was demonstrated not to work — that part is measured. The
exposure **itself** has not been stood up: a remote commit adding a file under a
protected folder, pulled, and the file then fetched anonymously. That is the
first task.

# Not attempted

- **Refusing the pull** when a changed path is gated. Plausible, and it turns a
  silent exposure into a stuck sync; wants the same ACL-store read to decide,
  so it does not avoid the question. **Put to the release manager on
  2026-09-14 and NOT chosen** — relocating is the behaviour, because a remote
  commit should not be able to block a site's sync entirely. Note this was
  only ever a choice about what happens *after* the answer, so the resolver is
  needed either way and nothing is lost if this is revisited.
- **Warning after the fact.** Cheap, and it leaves the file public.

# Related

[[SM852]] (this was its S6), [[SM836]], [[SM286]].
