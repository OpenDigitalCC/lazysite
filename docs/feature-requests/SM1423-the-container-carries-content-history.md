---
id: SM1423
title: "SM1423: the container carries content history, and the move from the 0.16.1 recipe is written out"
subtitle: "Neither container image installed git, so content history could not be turned on there, and the Docker README did not say how a site moves from the 0.16.1 recipe. The image installs git; the README has the numbered steps."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "release manager, ruling 227 (the 0.16.1-recipe migration walk)"
area: docker
status-note: "SHIPPED (0.16.10): the image installs Debian's git; content history is off until turned on, one command in the README. The README's new section moves a 0.16.1 site in eight steps: volume names, create, copy as www-data, site_url, add, history. UPGRADE.md points at it. The upgrade sets declared modes on every declared directory (form-events was 2755). t/lint/563, t/tools/581."
---

# What happened

The migration walk (n802) found that neither the 0.16.1 nor the 0.16.9 image installs
`git`, so content history cannot run in the container, and the README did not say so.
UPGRADE.md's paragraph on the old Docker recipe said to copy into "the new volume" but
not how that volume exists before the first `up`, which volumes are named what (compose
prefixes the project name), what ownership and modes the files need, or that the old
`site_url` and `site_name` stay in the copied `lazysite.conf`.

# What changed

- The Dockerfile installs `git`, Debian's own, unpinned. `lazysite check` already
  reports a missing `git` when `git_history` is enabled; that report is kept.
- `installers/docker/README.md` has a "Content history" section (the command that turns
  it on) and "Moving a site from the 0.16.1 recipe", in eight numbered steps with exact
  commands, each traced through the 0.16.1 and 0.16.9 compose files, the entrypoint and
  `lazysite-sites`.
- UPGRADE.md's paragraph points at the steps, and notes the image now carries `git`.
- t/lint/563 reads the Dockerfile's package list and holds it to the programs the engine
  runs (`git`, `curl`, `nginx`), and checks the engine file that runs each still does.
- The install's mode step (ruling 215) now sets the declared mode, mode only, on every directory
  the model declares: install_dirs (the check's "declared directories" list) and the runtime
  paths marked repair. The 0.16.1 recipe left lazysite/stats/form-events at 2755, which the check
  FAILs and the upgrade-on-start left, so a moved site was refused. t/tools/581 holds it.
