---
title: "SM571: the history summary walks the history once"
subtitle: "git-history-summary always timed out at the gateway. It ran a lineage walk - several git processes, following renames - for every tracked file, so the cost was files times history and a site recording since 0.7.x never answered inside thirty seconds. The summary now reads the history once and reproduces the same lineage rules as it goes."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND BY THE SITE AGENT 2026-08-25 on edge (inbox filing) during the manage_content capability sweep: git-history-summary 504'd after 30s with or without a path and with or without limit=1, while git-status and git-history answered the same site in about a second. Root cause: Lazysite::Git::files_summary ran file_log (up to four git invocations, rename-following) for EVERY path in ls-tree HEAD - O(files x history); limit made no difference because the action takes no limit. SHIPPED 0.10.32 (EDGE) (rides the next cut): one ls-tree plus ONE `git log --name-status -z --no-renames` walk, newest first, aggregating per-path revisions/first/latest/last_author with the SM175 lineage rules kept by construction - an incarnation ends at its add commit (no leak across a delete-and-recreate), a Lazysite-Renamed-From trailer on that add commit continues into the source path's older commits (a rename keeps its pre-rename count), 200-revision per-path bound as before. Output shape, sort and _norm_rel skipping unchanged; run_git remains the only git seam. t/unit/lib/20-git-summary.t pins it: 40 files x 3 commits in at most 3 invocations (124 before, 2 after) with the counts the per-file walk gave."
---

# The report

The site agent's capability-row sweep on `edge.explore.lazysite.io` (engine
0.10.31) found `git-history-summary` returning the front end's HTML 504 page
after thirty seconds, every time - no path, a path, `limit=1` - while
`git-status`, `git-history` and `content-history` answered the same account
on the same site in under a second. The filing ruled out the git subsystem,
the scope and the capability, and asked whether the summary walked the whole
history before honouring a limit.

# The cause

It walked the whole history *per file*. `files_summary` listed the committed
tree (`ls-tree -r HEAD`) and then called `file_log` for each path. `file_log`
is the per-file view's lineage walk: a `git log --diff-filter=A` to find the
incarnation's add commit, a `git log` over the path, a trailer lookup, and
the same again for every recorded rename. Four processes per path on a small
site, more on one with moves - and on a repo recording since 0.7.x, hundreds
of `git log` invocations each scanning the full history. Files times history.

`limit` made no difference because the action has never taken one: the
registry entry is `params: []`, and the dispatcher passes only the scopes.
The parameter was ignored rather than applied late.

# The fix

One listing, one walk. `ls-tree` still defines the set (the tracked content
at HEAD, exactly what `info/exclude` has kept clean), and then a single
`git log -z --no-renames --name-status`, newest first, is read once. Every
HEAD path starts *open* under its own name; each commit that touches an open
name counts as a revision (updating `first`, and `latest`/`last_author` on
the newest); a commit that *adds* the name closes it, and if that commit
carries a `Lazysite-Renamed-From` trailer the source name is opened for the
same target from the next-older commit on. That is `file_log`'s SM175 rule
expressed as a state machine over one stream:

- a delete-then-recreate at a reused path starts clean, because the
  recreation's add commit closes the path before the dead file's commits are
  reached;
- a recorded move keeps its pre-rename revisions under the current path;
- the per-path bound of 200 revisions is kept, and a bound reached
  mid-lineage does not follow the rename, as the per-file view's limit does
  not;
- git's own rename detection is switched off for the walk - the trailer is
  the recorded move, a similarity guess is not.

The output shape (`files: [{path, revisions, first, latest, last_author}]`
sorted by path, `summary: {files, revisions}`), the `_norm_rel` skipping and
the empty-never-error contract are unchanged, and `run_git` remains the only
way git is invoked.

# The one semantic difference

An incarnation with *no* add commit anywhere in the history - a file present
in a root commit made without the engine's own init - counts every commit
touching the path, as the per-file view does, but the walk does not consult
a trailer for it, because there is no add commit to carry one. Every repo
the engine initialised records its adoption as an add, so no live site is
affected; it is stated here so nobody reads the two views as byte-identical
in that corner.

# Not done

- **`limit`.** The primary fix removes the reason for one. Adding the
  parameter means the registry, the dispatcher, the MCP twin's schema and
  the generated action reference all move together (lint 23/52/58); left for
  a day it is asked for.
- **JSON on timeout.** The filing's second ask - fail as `{"ok":false}`
  rather than the gateway's HTML - is a front-end contract, out of this
  fix's reach and worth its own number if another action proves unbounded.
