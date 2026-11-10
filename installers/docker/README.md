# lazysite in Docker Compose

One container serves many sites. The engine and its extensions are the image,
read-only. The sites are folders in one volume, listed in its `sites.conf`. Each
site has its own FastCGI pool and its own persistent runtime (`lazysited`), and
nginx in front routes each request by its `Host`. Built on your machine from the
release tarball - there is no registry image and nothing is pushed.

The container belongs to one operator. Every site runs as `www-data`, and only
the image's own extensions run (a site's own extension file is refused, and
`lazysite check` names it). A site whose end user takes it over moves to a
dedicated service: Hestia, or a container of its own.

## Build and start

```bash
tar xzf lazysite-X.Y.Z.tar.gz
cd lazysite-X.Y.Z/installers/docker
docker compose build
docker compose up -d
docker compose exec lazysite lazysite-sites add example example.com www.example.com
docker compose exec lazysite lazysite-sites sysop example NAME
```

The build context is the unpacked tarball (`compose.yaml` sets it to `../..`),
so the image holds exactly that release. The one thing pulled is the Debian
trixie base image (the release the `.deb`s target); the Debian packages the
engine needs are installed from Debian's archive.

The container serves plain HTTP on port 8080, published on loopback. TLS and
the public names are your own proxy's job: `front.conf.example` is an nginx
example that keeps `Host` and passes every site to the container. To publish
on another address or port, set `LAZYSITE_BIND` and `LAZYSITE_PORT` (shell
environment or a `.env` file beside `compose.yaml`).

| Variable | Default | Meaning |
|---|---|---|
| `LAZYSITE_IMAGE` | `lazysite:local` | The image tag. The tag is the upgrade (below). |
| `LAZYSITE_BIND` | `127.0.0.1` | The host address the port is published on. |
| `LAZYSITE_PORT` | `8080` | The host port. |
| `LAZYSITE_WORKERS` | `2` | Each site's pool size: the per-site load limit. The container's own memory limit bounds the total. |

## The sites

`lazysite-sites` runs inside the container (`docker compose exec lazysite lazysite-sites ...`):

| Command | What it does |
|---|---|
| `add NAME DOMAIN [ALIAS...]` | lists the site and starts it: a fresh site on its first start. No restart. |
| `remove NAME` | stops the site and drops it from the list. Its folder is kept; delete it yourself. |
| `status` | each site's state, probed through nginx. Exits 1 when any site is not serving. |
| `restart NAME` | tries a refused or crashed site again, once you have fixed what it named |
| `check NAME` | `lazysite check` for one site |
| `sysop NAME USER` | the site's first account: a single-use link for that person to set a password |
| `restore NAME BACKUP` | puts the site back to a backup the upgrade took (rollback, below) |
| `rollback-plan` | each site's backups, and the restore commands |

A fresh site has **no accounts**, by design: `sysop` makes the first.

### One volume, a folder per site

| Path in `lazysite-sites` (mounted at `/srv/sites`) | Holds |
|---|---|
| `sites.conf` | one line per site: `NAME DOMAIN [ALIAS...]`. Aliases share the site. |
| `NAME/html` | the site's docroot: its pages and assets, and the manager's pages and assets, copied in at every start |
| `NAME/html-lazysite` | its settings, accounts, stores, keys, logs, backups and install state, and the engine's templates, copied in at every start |
| `NAME/html-lazysite-private` | its protected content |

Nothing of the engine is copied into a site: every site runs the image's.

## Starts, upgrades and rollback

At every start, each site is brought to the image on its own, decided by its own
install state:

| The site's state | What happens |
|---|---|
| none | provisioned: a fresh site, seeded with its first domain |
| older than the image | upgraded (`install.pl --mode upgrade --force`: you chose the image, so the site's update channel does not veto it; recorded in its audit log). A backup is taken first. |
| at the image's version | reinstalled: the engine's templates, manager pages and assets are copied in again |
| **newer than the image** | **refused**: an older engine is never run on newer state. The log prints the restore command, and the site answers 503. The other sites serve. |

**Upgrade.** Build the new release under a new tag
(`LAZYSITE_IMAGE=lazysite:X.Y.Z docker compose build`), set `LAZYSITE_IMAGE`
to it in `.env`, then run `docker compose up -d`. Every site moves with the image.

**Canary.** A one-site canary needs a second container: a second compose
project, its own volume holding that one site, on the new tag. Once it has run
well, move the main container's tag.

**Rollback.** The old tag runs a site only once the site is restored to the
backup its upgrade took. `lazysite-sites rollback-plan` lists each site's
backups. For each upgraded site run `lazysite-sites restore NAME BACKUP`, then
set the old tag and run `docker compose up -d`. A site left unrestored is
refused by the old image, and is named.

## Content history

The image carries `git`, so a site can record a version of every change. It is
off in a new site, and in a site moved from an older recipe. To turn it on
(this also takes the first snapshot of the site):

```bash
docker compose exec lazysite perl /usr/share/lazysite/extensions/content-history.pl \
    --docroot /srv/sites/example/html --action enable
```

Ticking **Content history** on the manager's Extensions page does the same.
`docker compose exec lazysite lazysite-sites check example` then reports the
content-history lines as `ok`. A site that has `git_history: enabled` in its
`lazysite.conf` but no history behind it (it was enabled where `git` was
missing) is reported `inconsistent` by the extension's Status; the same
command repairs it.

## Moving a site from the 0.16.1 recipe

The 0.16.1 recipe kept one site in three volumes. These steps copy them into a
folder of the new volume. Nothing writes to the old volumes: they stay as they
are until you remove them, and are the way back. The steps use the site name
`example` and the host names `example.com` and `www.example.com`; use your own.

1. Find the old volumes and note what the old site is called. The project name
   is `lazysite` (the `name:` line of `compose.yaml`), so the volumes are
   `lazysite_lazysite-docroot`, `lazysite_lazysite-settings` and
   `lazysite_lazysite-private`; a project started with `-p` or
   `COMPOSE_PROJECT_NAME` has that name in place of the first `lazysite`. In the
   old recipe's folder, while its container is still running:

   ```bash
   docker volume ls --filter name=lazysite
   docker compose exec lazysite grep -E '^(site_name|site_url):' /srv/lazysite/html/lazysite/lazysite.conf
   ```

2. Unpack the new release and build its image under its own tag, so the old
   image stays:

   ```bash
   tar xzf lazysite-X.Y.Z.tar.gz
   cd lazysite-X.Y.Z/installers/docker
   echo 'LAZYSITE_IMAGE=lazysite:X.Y.Z' > .env
   docker compose build
   ```

3. Stop the old container and remove it, keeping its volumes. In the old
   recipe's folder (never with `-v`, which deletes the volumes):

   ```bash
   docker compose down
   ```

4. Create the new volume. In the new folder, `docker compose create` makes the
   container, not started, and the volume `lazysite_lazysite-sites`, which the
   copy needs to exist:

   ```bash
   docker compose create
   ```

5. Copy the three old volumes into the folder `example` of the new volume,
   running as `www-data` from the new image (the image's own user; do not add
   `--user root`). `www-data` owns what it extracts, which is what the site
   needs, and `tar -p` keeps every file's mode. The docroot's own `lazysite/`
   (where the settings volume was mounted) is left out, because the settings
   go to `example/html-lazysite`:

   ```bash
   docker run --rm --entrypoint bash \
       -v lazysite_lazysite-docroot:/old/docroot:ro \
       -v lazysite_lazysite-settings:/old/settings:ro \
       -v lazysite_lazysite-private:/old/private:ro \
       -v lazysite_lazysite-sites:/srv/sites \
       lazysite:X.Y.Z -c '
           set -eo pipefail
           mkdir -p /srv/sites/example/html /srv/sites/example/html-lazysite /srv/sites/example/html-lazysite-private
           tar -C /old/docroot --exclude=./lazysite -cf - . | tar -C /srv/sites/example/html -xpf -
           tar -C /old/settings -cf - . | tar -C /srv/sites/example/html-lazysite -xpf -
           tar -C /old/private -cf - . | tar -C /srv/sites/example/html-lazysite-private -xpf -
       '
   ```

6. Set the site's name in the copied `lazysite.conf`. The old recipe wrote
   `site_name` and `site_url` from `LAZYSITE_DOMAIN` when it first started, and
   neither the copy nor the upgrade changes them. Make them name the site's
   main host, the first one you give `lazysite-sites add` in step 7 (leave
   `site_url` alone if it is already right, for example an `https://` one you
   set yourself):

   ```bash
   docker run --rm --entrypoint sed \
       -v lazysite_lazysite-sites:/srv/sites \
       lazysite:X.Y.Z -i \
       -e 's#^site_name:.*#site_name: example.com#' \
       -e 's#^site_url:.*#site_url: ${REQUEST_SCHEME}://example.com#' \
       /srv/sites/example/html-lazysite/lazysite.conf
   ```

7. Start the new container and add the site. `add` takes the folder name, then
   every host name the site answers to: the first is the main one (the name
   `lazysite-sites status` probes), the rest are aliases of the same site. They
   are the names your proxy forwards in `Host`. The site's install state is
   older than the image, so it is upgraded as it starts, and a backup is taken
   first (`example/html-lazysite/backups/lazysite-backup-*-pre-X.Y.Z.tar.gz`):

   ```bash
   docker compose up -d
   docker compose exec lazysite lazysite-sites add example example.com www.example.com
   docker compose exec lazysite lazysite-sites status
   ```

   `status` exits 0 and shows `example` as `serving`.

8. Turn on content history, which the old image could not run (see Content
   history above), and check it:

   ```bash
   docker compose exec lazysite perl /usr/share/lazysite/extensions/content-history.pl \
       --docroot /srv/sites/example/html --action enable
   docker compose exec lazysite lazysite-sites check example
   ```

   The check's content-history lines read `ok`. Saves are recorded from now on.

When the site has run well, remove the three old volumes
(`docker volume rm lazysite_lazysite-docroot lazysite_lazysite-settings lazysite_lazysite-private`).
Until then, the way back is `docker compose down`, the old recipe's folder and
`docker compose up -d`.

## Faults, health and logs

A site whose install fails, whose state is damaged, or whose health check names
a failure is **refused**. It is not started and it answers 503, while the other
sites serve. `lazysite-sites status` and the log name the fault and the command
to look further (`lazysite-sites check NAME`). Repair it, then run
`lazysite-sites restart NAME`.

A site reads `starting` until its pool accepts connections and nginx serves its
block, and only then reads `serving`. `add`, `restart` and `restore` wait for
that, or for `refused` with the reason: a pool that does not accept within 60
seconds is refused. Each such wait has a limit, so none can hang.

A site's pool that dies is restarted for that site alone, with a backoff. After
five crashes in ten minutes the site is left `crashed` (503) until
`restart NAME`.

A site's runtime (`lazysited`) can refuse to start because a service state file
in `NAME/html-lazysite/daemon/` cannot be read. That runtime is not restarted: a
restart cannot repair a file. The site still serves pages. `status` shows it as
`runtime-down` and names the directory. Repair the file, then run `restart NAME`.

Each reload tests nginx's configuration first. If nginx refuses it, the log
gives nginx's reason, and `status` names it on its first line and exits 1. nginx
keeps serving the last configuration it loaded.

The container refuses to start when it cannot write its run directory,
`/run/lazysite`, and the log names the path. Keep the `tmpfs` lines in
`compose.yaml` as they are: compose mounts a bare entry root-owned, and the
container runs as `www-data`.

The container is unhealthy, and exits, only when nginx or its supervisor is
down. One bad site never marks it unhealthy: watch `lazysite-sites status`
(exit 1) for that. nginx's logs go to the container's streams
(`docker compose logs`). Each site's own logs are in `NAME/html-lazysite/logs/`.

`lazysited` exits at once while a site's `daemon` extension is off. It is tried
again every five minutes (as `lazysited@.timer` does), so switching the
extension on in the manager is picked up.

## Security

Every process runs as `www-data`. The root filesystem is read-only, the
container drops all capabilities and sets `no-new-privileges`, and the engine is
root-owned in the image. Sites share one user, so the separation between them
is the engine's confinement of each request to its own site, not the operating
system's. That is why the container is one operator's. The engine's trust
headers are cleared in each vhost, as in the other templates. Behind your
proxy, set each site's `trusted_proxies` (the note in `docs/OPERATOR.md`).

Odoo: the image carries the Odoo extension, but not OOM (`libodoo-oom-perl` is
not in Debian's archive). A site that switches Odoo on is told the package is
missing.

## Removing it

`docker compose down` keeps the volume, and every site with it.
`docker compose down -v` deletes it. Back up first with each site's manager
backup, or with
`docker run --rm -v lazysite_lazysite-sites:/v -v "$PWD":/b debian:trixie-slim tar czf /b/sites.tgz -C /v .`.
