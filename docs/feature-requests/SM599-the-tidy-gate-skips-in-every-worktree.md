---
title: "SM599: the tidy gate skips in every worktree, so no branch is ever checked"
subtitle: "tools/tidy-check.pl tests for a .git DIRECTORY. A linked worktree has a .git FILE, so the check exits SKIP and the lint passes without looking at anything."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-25 when the 0.10.33 release build refused on t/lint/06 after every landing gate had passed it. FIRST EXPLANATION WAS WRONG and is recorded because it was plausible: the lint measures against the last release TAG, so a branch worktree and the merged trunk looked like they had different baselines. They do not - `git describe --tags` answers v0.10.32 in both, and perltidy is on PATH in both. PROVED BY RUNNING IT: a detached worktree at the exact commit whose code was untidy answers `tidy-check: SKIP - not a git checkout; pass files explicitly` and exits 0. The cause is one line - `unless ( -d \"$root/.git\" )` - and a LINKED WORKTREE'S .git IS A FILE containing `gitdir:`, not a directory. Every gate this project runs is run in a worktree, so t/lint/06 has been passing without examining a single line since worktrees became the landing path, and the first thing to notice was a release refusing at the end of a nine-minute build. FIXED by accepting either, which is what git itself does. THE COST WAS NOT THE TIDYING - eleven lines - but that a green gate meant less than it appeared to, and the check that was supposed to catch this is the one that was broken. Proven by t/lint/06 gaining an assertion that the tool does not skip in the tree it is running in, so a future skip is a failure rather than a pass."
---

# What was wrong

```perl
unless ( -d "$root/.git" ) { exit_skip('not a git checkout; pass files explicitly') }
```

A linked worktree's `.git` is a **file**:

```
$ cat /srv/tmp/b-580/.git
gitdir: /srv/projects/lazysite/.git/worktrees/b-580
```

so the directory test fails, the tool exits SKIP with status 0, and the
lint reports success having examined nothing.

# Why it went unnoticed

Every landing gate runs in a worktree. The release build runs in a
staging checkout that is a real clone, so it has a `.git` directory - and
is therefore the only place the rule was ever enforced.

A gate that cannot fail is worse than no gate: it is the reason nobody
looked.
