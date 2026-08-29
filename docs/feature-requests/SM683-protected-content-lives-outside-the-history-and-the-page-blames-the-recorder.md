---
title: "SM683: protected content cannot have history, because it lives outside the repository - and the page tells the operator recording is broken"
subtitle: "Release manager, 2026-08-28: 'sub sub sub folders that are protected don't record history ... this file reports: No versions recorded for this file ... version recording may be failing - run lazysite check'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). THE MESSAGE IS FIXED: a protected file no longer reports that recording may be failing and sends the operator to a diagnostic that reports health. The generic message survives for an unprotected file, where an empty history really is a fault. THE VERSIONING IS DECIDED AND NOT BUILT - the release manager ruled 2026-08-28 that protected content MUST be versioned, being the most important content, which turns the filing into a design: a second repository beside the private store and outside the docroot (never inside it - that would put a copy of every protected file in the served tree), with the store's own 02770 permissions, and two object stores rather than one repository with two work trees. THE ORDER IS NOT NEGOTIABLE: the per-file readers (git-history, git-show, git-restore) already apply the file's read ACL through _git_target, correcting an earlier claim in this filing that they do not; the gap is action_git_history_summary, which filters by scope and blocked paths and by no ACL, on a WIDER gate (manage_content|manage_config) than the readers it summarises - close that FIRST, or the migration publishes the path and revision count of every protected file. A third step nobody would think of: the public repository already holds orphaned history for paths since protected, and that becomes a copy of protected content in the public store the moment history is taken seriously."
---

# It is not depth, and it is not a fault

Two facts, neither of them wrong on its own:

`Private::private_root` puts protected content OUTSIDE the docroot
: `<parent>/<basename>-lazysite-private`, a SIBLING directory. Protecting a
  folder MOVES its content there (SM286) - that move is what puts it beyond the
  front door's reach, and SM650 is about the case where the rule saves and the
  move fails.

`Git.pm`'s work tree is the docroot, and it has never heard of the private store
: The module contains no reference to `Private` at all. `commit_paths` stages
  paths relative to the docroot.

So a protected file is not in the repository's work tree. It cannot be
committed, has never been committed, and will not be however many times it is
edited. "No versions recorded for this file" is exactly true.

The depth in the report is incidental. The determinant is PROTECTION - the files
higher up have history because they are not protected.

# The message is the part that costs time

> No versions recorded for this file. If it was changed after history was
> enabled, version recording may be failing - run `lazysite check`.

That sentence describes a fault. There is none: the repository is healthy,
recording works, and `lazysite check` will say so - sending the operator to
diagnose something that is behaving exactly as built. This is the SM237 class
again, and the SM672 class from this morning: a message pointing at the wrong
cause is worse than no message, because it is followed.

# DECIDED: protected content must be versioned

Release manager, 2026-08-28: *"yes, it must be, it's the most important
content. the question is then, how to protect the versioned content."*

That settles the first question and replaces it with a harder one. What follows
is the answer to the second, and the ORDER matters more than either half.

## The per-file readers are already safe. The SUMMARY is not

An earlier draft of this filing said `git-history`, `git-show` and
`git-restore` apply no ACL and would each become a way around it. **That was
wrong, and the correction narrows the work considerably.** All three resolve
their target through `_git_target` in `Lazysite::Manager::Files`, and that
helper ends with `_acl_denied( $r->{rel}, 'read', $username )`. A file's read
rule already governs its history, its diffs and its restores. Versioning
protected content does not open that door.

`action_git_history_summary` is the one that does not. It filters the file list
by `is_blocked_path`, `is_blocked_config` and `outside_all_scopes` - and by no
ACL at all - then recounts the totals so they describe the filtered set. It is
gated on `manage_content|manage_config` (SM664), which is a WIDER gate than the
per-file readers, applied to the one reader with a NARROWER filter.

Today that is harmless for the same reason as before: protected content is not
in the repository, so it cannot appear in the summary. The moment it is
versioned, a `manage_config` holder inside the right scope learns the path and
the revision count of every protected file - the existence and the edit rhythm,
not the bytes. For content whose protection is the point, a list of what exists
and how often it changes is not a small leak.

That is a smaller hole than the one this filing first claimed, and it is a real
one. It also cannot be reached from the manager UI today: SM664 removed the
history overview from the Files page. The action survives, so the API is the
surface.

So the sequence is not negotiable:

1. **DONE in 0.11.6.** `action_git_history_summary` now applies
   `_acl_allows($path, 'read', $username)` per entry, before the recount, so the
   totals keep describing the set the caller can see. Sabotage-verified three
   ways: removing the filter, counting revisions from the unfiltered set, and
   over-filtering to nothing each fail
   `t/unit/manager/103-the-history-summary-applies-the-acl.t`.

   The original wording of this step, kept because it is the rule: give it the
   ACL filter its per-file siblings - `_acl_denied( $path, 'read', $username )` per entry, before
   the recount, so the totals keep describing the set the caller can see. That
   is the rule the summary's own comment already states ("a number that
   disagrees with its own list is its own disclosure"); it simply applies it to
   scope and not to the ACL.
2. Only then move protected content into version control.

Doing them the other way round publishes, to any `manage_config` holder in
scope, the path and revision count of every protected file - between the two
steps, a directory of what is protected and how often it changes.

Worth noting what step 1 is NOT: the per-file readers need no change. Checking
this properly is what corrected the claim above, and it is the difference
between a day's work on one function and an audit of four.

## Where the history lives

A SECOND repository, beside the private store and outside the docroot -
`<parent>/<basename>-lazysite-private` gets its own git directory as a sibling
or a dotted child, never inside the docroot.

The reason is the private store's own reason. It is outside the docroot so that
no web-server misconfiguration can serve it. A repository holding the same bytes
inherits that requirement exactly: putting its git directory at
`<docroot>/lazysite/git-private` would place a complete copy of every protected
file inside the served tree, protected only by a deny rule - which is the shape
SM435 is about, and one misconfigured vhost from a disclosure.

It also needs the store's permissions, not the public repo's: `Private` creates
its directories `02770`, and the private history must match rather than inherit
whatever the public repo uses.

## What this does NOT need

Not a second work tree of one repository. Git can do it, but the two would share
one object store - and then the public repository CONTAINS protected content,
which is the disclosure this whole design avoids. Two repositories, two object
stores, two access rules.

## The history that already exists

Protecting a folder today DISCARDS the history its files had: past versions stay
in the public repository under the old path, orphaned and unreachable. Once
protected content is versioned, that becomes worse than a loss - it is a copy of
now-protected content sitting in the PUBLIC repository, readable by anyone who
may read the history at all.

So the migration has a third step nobody would think of: the public repository's
history for a path that is now protected has to be dealt with deliberately -
moved, or removed, or accepted and documented. It cannot simply be left.

# The original framing, kept for the record

**If protected content SHOULD have history**, the private store must be inside
the repository's reach - a second work tree, a second repo beside the private
root, or moving the store inside the docroot behind a deny rule instead of
outside it. That is a real piece of design: the store is outside the docroot
precisely so that no web server misconfiguration can serve it, and a git
directory beside it inherits that requirement.

**If protected content should NOT have history**, then the current behaviour is
right and only the message is wrong. It should say so where the operator is
looking - "protected content is not versioned; it lives outside the content
repository" - and say it on the folder as well as the file, so somebody about to
protect a folder learns they are trading its history away.

There is a real argument for the second: history of a protected file is a second
copy of protected content, in a store with its own access rules, and SM577's
lesson about instance-wide reach applies - a repository that carried protected
content would hand it to anyone who could read the repository.

# What must not be lost either way

Protecting a folder currently DISCARDS the history the files already had. Their
past versions stay in the repository under the old path, orphaned: the file is
gone from the work tree, so the history is unreachable from the Files page and
nothing says it exists. Whatever is decided about future versions, that silent
loss on a protection change is worth naming.

# Recommendation

The message is fixed in this release - it was unambiguously wrong, and it is
what the operator hit.

The versioning work is NOT in it, and should not be squeezed in. It is a new
repository, an access-control change to four verbs, and a migration for history
that already exists under paths since protected. The first of those three is the
one that must land first, and landing it alone is a useful release in itself:
gating the history verbs on the file's ACL is correct whether or not protected
content ever enters the repository.

# Related

SM286 (the move into the private store), [[SM650]] (a rule saved whose content
could not move - the same boundary from the other side), SM237 / [[SM672]] (a
message that names the wrong cause is followed), SM577 (an instance-wide store
is not scoped by the grant that reached it).

# Not started
