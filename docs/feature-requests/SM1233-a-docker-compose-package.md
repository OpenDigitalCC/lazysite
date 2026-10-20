---
id: SM1233
title: "SM1233: a Docker Compose package"
subtitle: "nginx, the one-rule FastCGI pool and lazysited in one container, the site in three volumes, built locally from the release tarball. Odoo is not in it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the release manager, tmp/rulings-2026-10-20.md (Docker Compose package, for the next release: 0.15.17)"
area: install
status-note: "SHIPPED (PENDING) on n715: installers/docker/ (Dockerfile, compose.yaml, entrypoint.sh, nginx.conf, README); shipped in the tarball via classification.json; docs/IMPLEMENTOR.md; t/tools/210. Built and run once by hand."
---

# What was asked

> "add to next release - a docker compose package."

Ruled scope: nginx and the one-rule FastCGI pool (under lazysited) in the
container; three volumes - the docroot, `lazysite/` (settings, accounts) and the
private store - with the engine code in the image; Odoo left out (no OOM, no
oomd, no Odoo extension); built locally from the release tarball with
`docker compose build`, no registry push.

`installers/docker/` held only a `.gitkeep` since F0006, and `README.md` said there
was no Docker image yet.

# What shipped

- `installers/docker/Dockerfile`: Debian trixie (what the debs target), the
  packages of `lazysite-common`'s Depends and Recommends plus nginx and curl, the
  unpacked release copied to `/usr/share/lazysite` where the debs put the payload,
  and the vhost made by `sed` from `installers/nginx/vhost-one-rule-pool.conf.example`
  - the template is the one place the rule is written. Runs as `www-data`.
  Nothing is installed into the volumes at build time.
- `installers/docker/compose.yaml`: one service, the three volumes
  (`/srv/lazysite/html`, `/srv/lazysite/html/lazysite`,
  `/srv/lazysite/html-lazysite-private` - the private store is where `install.pl`
  and the engine put it, the docroot's sibling), a healthcheck, all capabilities
  dropped, published on loopback by default.
- `installers/docker/entrypoint.sh`: runs `install.pl` - the one install path -
  chosen by the install state in the volume: no state is `--mode provision` with
  `LAZYSITE_DOMAIN`; state at this image's version is nothing (the volumes'
  data is left alone); a new container over the same volumes is `reinstall`
  (the engine's copy lives in the container layer); another version is
  `upgrade --force`. Then the pool (`FRONT_DOOR=1`), `lazysited` (retried every five
  minutes while the plugin is off, as the timer does) and nginx, stopped together on
  SIGTERM; the pool or nginx dying ends the container.
- The first account is `setup-sysop`, as `print_next_steps` says; the entrypoint
  prints the command at the first start, the README and the implementor guide give it.
- Release: `^installers/docker/` is no longer export-excluded; a classification
  rule lists the package as tarball-only (`install_to: null`), so the manifest
  builder accepts it and a fresh install does not stop on a new path (SM1226).
- t/tools/210 (no Docker): the compose file's three volumes and mounts and no
  Odoo, the Dockerfile's `sed` run on the real template, the entrypoint's
  provision / nothing / reinstall / upgrade decisions and its start and stop against
  stubs, and the manifest builder on the package.

# Not done

- No registry image, no push, no deb: the package ships in the tarball only.
- TLS is the front end's job; the container serves plain HTTP on 8080.
- Odoo in a container is a separate question.
