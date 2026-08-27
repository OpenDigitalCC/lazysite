# lazysite on HestiaCP — install runbook (packaged flow)

Status: current (SM139 increment 4). lazysite on Hestia is installed
from the **debs** — `lazysite-common` (engine payload + `lazysite` CLI)
and `lazysite-hestia` (web templates + `lazysite-hestia-domain`). The
hand-run scripts in this directory (`install-hestia.sh`,
`lazysite-hestia-deploy.sh`, `lazysite-hestia-update-all.sh`, the
`lazysite-app` template) are **superseded** by the packages; they stay
in the tree only because existing deployments still reference them —
see the appendix.

## Model

- The **debs** own the host payload (`/usr/share/lazysite`), the CLI,
  the site registry (`/etc/lazysite/sites.d/`), the FastCGI pool
  machinery (`lazysite@.service`, `/etc/lazysite/pools/`) and the
  Hestia web templates. Installing/upgrading a deb never touches a
  site tree.
- The Hestia **web template** owns the Apache vhost (routing, header
  strips, the `/lazysite/` deny). Two patterns ship:
  - `lazysite-cgi` — plain CGI; every page request routes through the
    cookie-auth wrapper via `FallbackResource`. Zero extra moving
    parts.
  - `lazysite-fcgi` — visitor pages proxy to a persistent per-domain
    FastCGI pool (`lazysite@<domain>`, socket
    `/run/lazysite/<domain>.sock`, ~150x faster on cache hits); the
    auth wrapper, manager traffic and all `/cgi-bin/`+`/dav` endpoints
    stay on the CGI path (the wrapper is not pooled — its
    per-request trust-header exec is the design, see
    `docs/architecture/performance.md`).
- `lazysite-hestia-domain` (root-run, from `lazysite-hestia`) owns
  **per-domain onboarding**: it prepares the panel-specific layout as
  root, then **drops to the panel user** for provisioning — no root
  writes into site trees (SM139), so ownership is correct by
  construction and no chown-after repair pass exists in this flow.

## One-off host setup

Prereqs: Hestia with `WEB_SYSTEM=apache2` (php-fpm backend, nginx
proxy in front). lazysite requires the apache2 backend — a nginx-only
domain cannot route `/cgi-bin/` or `/dav`.

1. Install the packages (from `dist/ (in the lazysite checkout)` or the apt
   repo once published):

   ```bash
   apt install ./lazysite-common_<ver>_all.deb ./lazysite-hestia_<ver>_all.deb
   ```

2. Copy the web templates into Hestia's template dir. Hestia scans
   `$WEBTPL/$WEB_SYSTEM/$WEB_BACKEND/` — i.e.
   `/usr/local/hestia/data/templates/web/apache2/php-fpm/`, NOT
   `.../apache2/`; one level too high and the template never appears
   in `v-list-web-templates`:

   ```bash
   cp /usr/share/lazysite-hestia/templates/lazysite-cgi.?tpl \
      /usr/share/lazysite-hestia/templates/lazysite-fcgi.?tpl \
      /usr/local/hestia/data/templates/web/apache2/php-fpm/
   ```

3. Copy the **nginx proxy** template into Hestia's other template
   directory. This is a second layer, not a variant of step 2:

   ```bash
   cp /usr/share/lazysite-hestia/templates/lazysite-proxy.?tpl \
      /usr/local/hestia/data/templates/web/nginx/
   ```

   SM283. The path here is nginx → Apache, and everything lazysite
   enforces lives in the Apache half. Hestia's stock proxy answers a
   fixed list of static **extensions** off the docroot, so a request
   for a `.png`, `.pdf`, `.txt` or `.zip` inside a protected section
   is served before Apache is involved and no access rule can reach
   it — the section gates its pages and publishes its files. Deciding
   this by extension cannot be made safe: any list is a list of the
   types that happen to be protected. `lazysite-proxy` hands those
   requests back to Apache whenever the site has an ACL store, and
   changes nothing for a site without one.

4. Enable the Apache modules the templates use, then restart:

   ```bash
   a2enmod headers rewrite        # both patterns
   a2enmod proxy proxy_fcgi       # lazysite-fcgi only
   a2enmod include                # only for overlaid SSI (.shtml) sites
   systemctl restart apache2
   ```

## Per-domain onboarding (4 steps)

1. Create the web domain in Hestia as usual (panel or
   `v-add-web-domain <user> <domain>`).

2. Provision (as root — it drops to the panel user for every
   site-tree write):

   ```bash
   lazysite-hestia-domain add <user> <domain>           # plain CGI
   lazysite-hestia-domain add <user> <domain> --fcgi    # FastCGI pool
   ```

   `--channel edge|stable` and `--policy auto|manual` pass through to
   `lazysite provision`. With `--fcgi` it also writes
   `/etc/lazysite/pools/<domain>.conf` and runs
   `systemctl enable --now lazysite@<domain>`.

3. Apply the matching template (rebuilds the vhost):

   ```bash
   v-change-web-domain-tpl <user> <domain> lazysite-cgi yes    # or lazysite-fcgi
   ```

4. Apply the proxy template, so the front end respects the same
   access rules:

   ```bash
   v-change-web-domain-proxy-tpl <user> <domain> lazysite-proxy
   ```

   Confirm which front end answered, with no credentials and from
   anywhere:

   ```bash
   curl -sI https://<domain>/ | grep -i x-lazysite-front
   # X-Lazysite-Front: hestia-proxy/acl
   ```

   No header means the domain is still on a stock proxy template.
   That header exists because SM283 had no observable: three rebuilds
   and a template install all produced byte-identical responses,
   because none of them touched this layer.

First-run site steps (unchanged from the tarball era):

- Set the manager password:
  `sudo -u <user> lazysite users --docroot <docroot> setup-sysop --user <name>`
  (prints a generated password once; the seeded `manager` account is
  otherwise empty-password = localhost-only).
- WebDAV publishing needs BOTH gates on: `webdav_enabled: yes` in
  `lazysite/lazysite.conf` (site gate, default off → `/dav` is 404)
  and `set <user> webdav on` per user.
- Delete Hestia's placeholder `index.html` from the docroot if it
  shadows the markdown homepage (nginx serves `.html` statically).

Health check any time: `lazysite check --docroot <docroot>` (add
`--fix` to repair; `--check-dav https://<domain>` distinguishes a
routing 404 from the expected 401 challenge on `/dav/`).

## Critical invariant: FallbackResource → the auth wrapper

Both shipped templates encode the contract that pages route through
`lazysite-auth.pl` (the cookie becomes `X-Remote-User` before the
processor runs) and that the real `/cgi-bin/*.pl` endpoints are
fronted by the same wrapper via mod_rewrite. Pointing
`FallbackResource` straight at the processor makes every login
silently ineffective (`/manager/` redirect loop). If you fork a
template, keep those lines — they are commented in place, and
`t/tools/30-hestia-pkg.t` guards the shipped copies.

In the `lazysite-fcgi` template the same contract holds differently:
requests carrying the `lazysite_auth` session cookie are rewritten to
the CGI auth wrapper; only cookie-less visitor traffic reaches the
pool socket. The pool is anonymous by design.

## Upgrades

- **Engine/host**: upgrade the debs (`apt install ...` / apt repo).
  This refreshes `/usr/share/lazysite` only — no site is touched.
- **Sites**: `lazysite upgrade --all` (as root; drops to each owner).
  Per-site `update_policy: manual` (default) sites are skipped, and
  each site's `update_channel` gates which payloads it accepts;
  `--force` overrides both, `--force-security` overrides both
  fleet-wide but only for a payload whose manifest declares
  `"security_critical": true`. `lazysite sites` lists the fleet.
- **Pools**: a pool picks up upgraded site code on restart:
  `systemctl restart lazysite@<domain>` after upgrading that site.
- **Front end (SM283)**: a package upgrade **cannot** deliver this
  one. The layer at fault is nginx, and no Hestia proxy template
  shipped before 0.10.7, so an existing domain keeps serving gated
  statics until it is moved onto `lazysite-proxy` explicitly. For the
  whole host at once:

  ```bash
  lazysite-hestia-list.sh                          # who is affected
  lazysite-hestia-update-all.sh --proxy            # stage + apply, rebuilds vhosts
  ```

  `lazysite-hestia-list.sh` flags a domain with an ACL store on a
  stock proxy as `ACL-BYPASSED-BY-PROXY(SM283)` — that one is exposed
  now — and shows the rest with their current proxy template, which
  is the gap before anyone protects a folder. This is the same shape
  as SM248: correct engine code made unreachable by front-end
  routing, and therefore fixed by deployment configuration rather
  than by code that ships in the payload.

## Taking a domain off lazysite

```bash
lazysite-hestia-domain remove <domain>       # stops pool, deregisters
v-change-web-domain-tpl <user> <domain> default
```

`remove` never deletes the docroot: the lazysite files left in place
are inert without the template.

## Appendix: legacy hand-run flow (superseded)

Until 0.7.1 the Hestia story was hand-run from an unpacked tarball:
`lazysite-hestia-deploy.sh USER DOMAIN STAGE` per site (template +
root-run install + permission sweep), `lazysite-hestia-update-all.sh`
for fleet updates, and the `lazysite-app` `.tpl/.stpl/.sh` template
trio. Those scripts remain in this directory untouched for existing
deployments, but new installs must use the packaged flow above — the
deploy scripts' root-run install + chown-after model is exactly what
SM139 removed.

For the old runbook text (the full manual procedure, the
`--domain` minimal-conf trap, the permissions model, the WebDAV/davfs2
tuning notes and the 2026-06-22 field validation), see this file's
git history: `git log --follow -p -- installers/hestia/INSTALL-RUNBOOK.md`
(last hand-run revision: the tree at tag `v0.7.1`).
