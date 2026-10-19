---
id: SM1187
title: "SM1187: a stage another user cannot remove does not stop a run"
subtitle: "The next run clears the stages it can, names the ones it cannot, and says who can remove a kept stage."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-19
raised-by: release manager, from the 0.15.10 cut (n674)
area: release
status-note: "SHIPPED (PENDING) on n674: tools/release.sh (prune_dead_stages, stage_disposition, writable stage dir), tools/stage-default.sh (per-user root); t/tools/184."
---

# What happened

The developer agent's first 0.15.10 gate (unix user `claude`) failed on the
bench and kept its stage at `/var/tmp/lazysite-stage/lazysite-release-237354`
("a failed stage is kept for inspection and removed at the start of the next
run", SM895 G3). The release manager then ran the gate as their own user and it
stopped in 0 s:

    rm: cannot remove '/var/tmp/lazysite-stage/lazysite-release-237354/docs/feature-requests/SM789-...md': Permission denied

Every file in the stage was owned by `claude`, group `claude`, mode 0664/0775.
`prune_dead_stages` ran `rm -rf` under `set -e`, so a leftover the current user
cannot remove ended the run before it began.

# What shipped

The class, not the instance: a leftover this user cannot clear.

- A run uses a stage of its own (the pid is in the name, as before) and
  `prune_dead_stages` clears only a stage it can clear whole: write and search on
  the stage base and on every directory in the tree, asked first with `find`, so
  a stage is removed whole or left whole, never half-removed. One it cannot clear
  is named as a warning - its owner, its age in days, and the command to remove
  it - and the run goes on.
- The kept-stage message (`stage_disposition`) now ends with who can remove it
  and the command: only the running user, or root. Stages are not made wider.
- The stage root. `tools/stage-default.sh` uses `/var/tmp/lazysite-stage` as
  before wherever the user can write it; where it exists and the user cannot
  write it, the default is `/var/tmp/lazysite-stage-USER`, with a line saying
  why. Chosen over a fixed per-user root (which would orphan every existing kept
  stage and change a path people know) and over a sticky world-writable root
  (which lets any local user plant a stage-shaped directory for the gate to run).
  An explicit `--stage-dir` that is not writable is refused by `release.sh` with
  the way out named, rather than a bare `mkdir` error.

Tests: `t/tools/184-a-stage-another-user-cannot-remove-does-not-stop-a-run.t`
(a stage under a directory the test cannot write, in a temp dir; no other real
user). It fails on the unchanged scripts and passes on the fixed ones.
