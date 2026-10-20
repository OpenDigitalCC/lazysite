# lazysite in Docker Compose

nginx, the one-rule FastCGI pool and the persistent runtime (`lazysited`) in one
container. The engine is in the image; the site is in three volumes. Built on
your machine from the release tarball - there is no registry image and nothing
is pushed. Odoo (OOM, `oomd`, the Odoo extension) is not part of this package.

## Build and start

```bash
tar xzf lazysite-X.Y.Z.tar.gz
cd lazysite-X.Y.Z/installers/docker
docker compose build
docker compose up -d
```

The build context is the unpacked tarball (`compose.yaml` sets it to `../..`),
so the image holds exactly that release. The one thing pulled is the Debian
trixie base image (the release the `.deb`s target); the Debian packages the
engine needs are installed from Debian's archive.

Open `http://127.0.0.1:8080/`. The container listens on plain HTTP and the port
is published on loopback only: TLS and the public name belong to the reverse
proxy in front of it. To publish on another address or port, set
`LAZYSITE_BIND` and `LAZYSITE_PORT` (shell environment or a `.env` file beside
`compose.yaml`).

| Variable | Default | Meaning |
|---|---|---|
| `LAZYSITE_DOMAIN` | `localhost` | The `site_url` domain a fresh site is seeded with. Read at the first start only. |
| `LAZYSITE_BIND` | `127.0.0.1` | The host address the port is published on. |
| `LAZYSITE_PORT` | `8080` | The host port. |
| `LAZYSITE_IMAGE` | `lazysite:local` | The tag `docker compose build` gives the image. |

## The first account

A fresh site has **no accounts**, by design, and there is no default login.
Create the first sysop, which prints a single-use link for that person to set
their own password:

```bash
docker compose exec lazysite perl /srv/lazysite/tools/lazysite-users.pl \
    --docroot /srv/lazysite/html setup-sysop --user NAME
```

Then sign in at `/manager/`. Run it again with another name for each further
sysop. Until the first sysop exists the manager is closed and `/manager/` answers
403; after it, `/manager/` sends a visitor to the sign-in page.

## The three volumes

| Volume | Mounted at | Holds |
|---|---|---|
| `lazysite-docroot` | `/srv/lazysite/html` | The docroot: pages, assets, the manager UI |
| `lazysite-settings` | `/srv/lazysite/html/lazysite` | `lazysite.conf`, accounts, forms, logs, backups, the install state |
| `lazysite-private` | `/srv/lazysite/html-lazysite-private` | The private store (protected content, outside the docroot) |

Everything else is the image: the engine (`/usr/share/lazysite`, and the
engine's copy installed beside the docroot at `/srv/lazysite/{cgi-bin,tools,lib,plugins}`),
nginx and its configuration.

## First start, later starts, upgrades

The entrypoint runs `install.pl` - the one install path - and decides what to do
from the install state in the settings volume, never from the container:

| State in the volume | What the entrypoint does |
|---|---|
| none (empty volumes) | `install.pl --mode provision`: a fresh site, with `LAZYSITE_DOMAIN` |
| at this image's version | Nothing. The volumes' data is left alone. |
| at this image's version, but a new container | `install.pl --mode reinstall`: lays the engine's copy again (it lives in the container, not a volume); content, accounts and config stay |
| at another version | `install.pl --mode upgrade --force`: you chose this image, so the site's update channel does not veto it; the override is recorded in the audit log, and a backup is taken first |

To upgrade: unpack the new tarball, `docker compose build`, `docker compose up -d`.

## Stopping, health and logs

`docker compose stop` sends SIGTERM; the entrypoint stops the pool, `lazysited`
and nginx together and exits 0. The container is marked unhealthy when
`http://127.0.0.1:8080/` stops answering, and exits (so `restart:
unless-stopped` restarts it) if the pool or nginx dies. nginx's access and
error logs go to the container's streams (`docker compose logs`); the engine's
own logs are in `lazysite/logs/` in the settings volume.

`lazysited` exits at once while the `daemon` plugin is off; the entrypoint tries
it again every five minutes (as `lazysited@.timer` does), so switching the
plugin on in the manager is picked up.

## Security

Every process runs as `www-data` (the pool's `USER`, as the templates have it);
the container drops all capabilities and sets `no-new-privileges`. The
engine's trust headers are cleared in the vhost, as in the other templates.
Behind a reverse proxy, read the `trusted_proxies` note in
`docs/OPERATOR.md` and set it for your proxy.

With a bind mount instead of a named volume, the host directory must belong to
uid 33 (`www-data`), mode 2775 for the docroot and `lazysite/`: a named volume takes the image's ownership by itself.

## Removing it

`docker compose down` keeps the volumes (and so the site). `docker compose down -v`
deletes them, and the site with them. Back up first with the manager's backup, or
`docker run --rm -v VOLUME:/v -v "$PWD":/b debian:trixie-slim tar czf /b/VOLUME.tgz -C /v .`
for each volume.
