---
title: "SM683: protected content cannot have history, because it lives outside the repository - and the page tells the operator recording is broken"
subtitle: "Release manager, 2026-08-28: 'sub sub sub folders that are protected don't record history ... this file reports: No versions recorded for this file ... version recording may be failing - run lazysite check'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). THE MESSAGE IS FIXED: a protected file no longer reports that recording may be failing and sends the operator to a diagnostic that reports health. The generic message survives for an unprotected file, where an empty history really is a fault. THE VERSIONING IS DECIDED AND NOT BUILT - the release manager ruled 2026-08-28 that protected content MUST be versioned, being the most important content, which turns the filing into a design: a second repository beside the private store and outside the docroot (never inside it - that would put a copy of every protected file in the served tree), with the store's own 02770 permissions, and two object stores rather than one repository with two work trees. THE ORDER IS NOT NEGOTIABLE: git-history, git-show and git-restore are gated on manage_content and apply NO ACL, which is harmless only while protected content is absent from the repository - gate the reader FIRST, or the migration opens a hole and closes it afterwards. A third step nobody would think of: the public repository already holds orphaned history for paths since protected, and that becomes a copy of protected content in the public store the moment history is taken seriously."
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

## The reader is the hole, and it must be closed first

`git-history`, `git-show` and `git-restore` are gated on `manage_content` and
nothing else. They apply no ACL.

Today that is harmless: protected content is not in the repository, so there is
nothing for the reader to hand over. **The moment protected content is
versioned, that reader becomes a way around the ACL** - any `manage_content`
holder could read the history of a file the ACL says they may not open, and
`git-restore` could write it back into the world.

So the sequence is not negotiable:

1. Gate the history verbs on the same ACL as the file. `Data::Access::may_read`
   and `Auth::Acl::_acl_allows` already answer this question for a path; the
   history reader must ask it too, per commit path, not once for the request.
2. Only then move protected content into version control.

Doing them the other way round opens the hole and closes it afterwards, and
between the two the repository is a copy of every protected file readable by a
grant that was never meant to see it.

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
