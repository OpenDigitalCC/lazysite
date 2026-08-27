---
title: "SM372 - a release did not build its packages, and the version came from a stale file"
subtitle: "Packages exist for every release up to 0.10.8 and then stop. Five releases have none, and building one by hand today would have labelled it 0.10.8 from 0.10.13 source."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18 at the operator's instruction to wire it into the release rather than remember it. Two halves: release.sh now builds the .deb set from the same staging clone as the tarball, and STAMPS debian/changelog from the release version in that stage rather than reading the repo's copy - so the package version cannot disagree with the tag by construction. Built before the tag, so a failure aborts a release that has not yet burned a version. The success check is per-package and by name at the release version, because 'dpkg-buildpackage exited 0' is not 'the packages exist'. Proved end to end against v0.10.13 with a synthetic version: four packages, correctly named, payload carrying the SM350 module."
---

# What was found

```datatable
columns: | 
widths: 6cm | X
bold: 1
tone: medium
---
packages in `dist/` | every release through **0.10.8**
0.10.9 - 0.10.13 | **none**
`debian/changelog` | still at **0.10.8-1**
---
```

Five releases with no packages, and nobody noticed. `release.sh` succeeded
without them, and **a step that is not part of a process which already succeeds
is a step that eventually stops happening.**

# The worse half

`dpkg` takes the package version from `debian/changelog`. That file sat at
`0.10.8-1` while the tree moved on, so building today by hand would have
produced `lazysite-common_0.10.8-1_all.deb` **from 0.10.13 source**.

A package whose version contradicts its contents is worse than a missing one:
apt declines to upgrade to it, and an operator reading `dpkg -l` is told
something false about what is installed. On 17 production sites that is not a
tidiness problem.

# What was done

Built in the release
: from the same staging clone as the tarball, so the payload is the tagged
  commit and nothing from a working tree leaks in.

Version stamped, not read
: the changelog entry is generated in the STAGE from `$VERSION`. The repo's own
  `debian/changelog` is untouched, and the mislabelling becomes **impossible
  rather than detectable**.

Before the tag
: a failure aborts a release that has not yet burned a version, and burned
  versions are never reused ([[SM064]]).

Checked positively
: every package named in `debian/control`, by name, at the release version. An
  exit status is not a package - a build can succeed and produce nothing, or
  produce the previous version's files, and both read as success against `$?`.
  The set is read from `debian/control` rather than repeated, so a fifth package
  is checked without editing `release.sh`.

An opt-out that says so
: `LAZYSITE_SKIP_DEB=1` cuts a tarball-only release out loud. A missing
  `dpkg-buildpackage` is otherwise an error, not a silent skip.

# Verification

- A release produces a `.deb` for every package in `debian/control`, at the
  release version.
- The package version matches the tag without anyone editing a file.
- A build that produces nothing, or the wrong version, fails the release and
  leaves no tag.
- `t/tools/45` asserts the wiring, the stamping, the positive check, and that
  the build runs before the tag.

# Related

[[SM139]] (the packaging this belongs to), [[SM064]] (burned versions are never
reused, which is why the build runs before the tag), and [[SM330]] / [[SM373]]
(the same "a hand-maintained list stops matching" mechanism, one release apart).
