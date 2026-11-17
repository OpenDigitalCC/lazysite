---
id: SM1475
title: "SM1475: a stable patch is built from its branch"
subtitle: "The release build releases only main's tip, and main carries the next release's unreleased work. A stable patch is gated on its own branch, so the build takes --ref BRANCH, puts the release on that branch, and leaves main for a merge."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-17
raised-by: "the release manager (ruling 274), with the 0.17.2 stable patch waiting"
area: release
status-note: "BUILT, not released: release.sh build --ref BRANCH (stable patch only; release commit, download/ commit and tag on the branch, main not moved, the merge to main printed), and publish waits for the tag to reach main. Release tooling only."
---

# What happened

Main carries the unreleased 0.17.3 work. The stable patch 0.17.2 is the branch
`claude/p0172-stable-patch-sm1473`: v0.17.1 plus its fixes and the 0.17.1 `download/` set, its
commits already merged to main. `tools/gate-main.sh --ref BRANCH --version 0.17.2 --final --patch`
gates the branch's own commit and writes a receipt that names that commit and the patch base.
`tools/release.sh build` then read main's tip, put its one release commit on main, tagged it
there and moved local main to it: building 0.17.2 that way would have released the unreleased
0.17.3 batch under a stable tag.

# What was asked

Build a stable patch from the branch it was gated on (ruling 274).

- `build VERSION --notes FILE --final --ref BRANCH`. `--ref` is the name `gate-main.sh` already
  uses for the commit it gates, and a build and its gate then name the branch the same way.
- Stable patches only. Refused off `--final`, for main, and for a branch that is not there.
  Refused unless the gate receipt for VERSION is a `--patch` receipt (it names `suite_base`) for
  the branch's current tip, the patch base is the line's newest release, the branch descends from
  the base tag, and the branch's `download/` holds the base's stable set (the newest stable).
- The release commit and the stable `download/` commit go on the branch's tip, the tag on the
  release commit, the branch ref moves to the `download/` commit; local main is not moved.
  Everything else is the existing build, shared: the lints on the release material, packaging,
  the tag annotation, a failure leaving the branch, main and the tags as they were.
- The release material tool and the checks are the branch tip's own, the ones the gate ran
  (the "differs from the one the gate ran" check holds).
- The build ends by printing the next step with real values: a branch from main
  (`claude/land-vX.Y.Z`, its worktree) that merges the branch's new tip, which is landed by
  fast-forward.
- `publish` pushes main and the tag together, atomically, and refuses unless the tag's commit is
  reachable from local main. It already did; with a patch tag that is the check that matters,
  and its refusal now says why (the merge has not landed). Nothing in `publish` changed
  otherwise: after the merge lands one `publish` pushes both, and the patch branch is not pushed.

# What was built

`tools/release.sh` (the build's base is a variable, main by default, the `--ref` branch with
it; the header says so), `docs/DEVELOPER.md` (Patch releases), t/tools/765 (the release goes on
the branch, main does not move; a branch checked out elsewhere moves with it; the main build is
unchanged), 766 (every refusal, each leaving branch, main and tags as they were), 767 (publish
refuses while the tag is off main and pushes both after the merge). `t/lib/ReleaseRig.pm` gains
`rig_patch_branch`. No register entry: this is release tooling, nothing a site runs.
