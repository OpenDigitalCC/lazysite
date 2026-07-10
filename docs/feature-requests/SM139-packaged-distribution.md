# SM139 - Packaged distribution: common .deb + environment .debs + unprivileged provisioning

Status: proposed (design agreed in principle 2026-07-09)
Driver: field incidents on the 0.6.4->0.6.5 upgrade round - 17 live production
sites, and every root-run write into a site tree (sudo install.pl, sudo
lazysite-users.pl) re-opens the www-data ownership gap. Per-site tarball
installs do not withstand automation.

## Problem

lazysite's engine ships as a tarball unpacked per-site with sudo. Three
structural consequences:

1. **Ownership fragility.** The CGI user (www-data) must read secrets and write
   config/cache, while the hosting panel (Hestia) owns web files as the site
   user. Any root-run tool that writes into the tree leaves root-owned files
   the CGI cannot touch: the auth wrapper 500s, config saves fail, the manager
   layout silently falls back. lazysite-check --fix repairs after the fact,
   but the model invites the breakage.
2. **No slick upgrades.** Upgrading 17 sites means 17 sudo installer runs, each
   a chance to repeat (1). Security fixes cannot be forced fleet-wide.
3. **Provisioning is manual.** Adding lazysite to a domain is a hand-run
   installer invocation, not a repeatable action a panel or script can drive.

## Design

### Package split

lazysite-common.deb
: The engine payload (cgi-bin scripts, lib/, starter/, plugins/, tools/) at
  `/usr/share/lazysite/<files>`, root-owned, read-only - plus a `lazysite`
  CLI in `/usr/bin` (provision / upgrade / check / backup / users verbs,
  wrapping today's tools). Installing/upgrading the deb NEVER touches site
  trees; it only refreshes the host payload. Also the right home for the dev
  server: `lazysite dev --docroot X` (today's tools/lazysite-server.pl).

lazysite-apache.deb / lazysite-nginx.deb
: Depend on common. Web-server glue: vhost/htaccess templates, the CGI/FCGI
  wiring, `lazysite provision` presets for that server.

lazysite-hestia.deb
: Depends on the apache/nginx one. Hestia integration: a web template and/or
  v-hook so "add lazysite to a domain" is a panel action; knows Hestia's
  user/group layout and drives provisioning correctly.

Tarball / git checkout
: Stays fully supported (dev mode and non-deb hosts). install.pl remains; the
  deb path wraps the same logic.

### The one load-bearing principle: no root writes into site trees

`lazysite provision <docroot>` and `lazysite upgrade <site>` run **as the site
user** (the Hestia hook context, or `sudo -u <siteuser>` from a root wrapper),
creating files `siteuser:www-data` with setgid dirs from the start. Root is
only ever needed to install the deb and (optionally) to drop privileges to the
site user. Ownership is then correct by construction - no chown-after pass, no
lazysite-check --fix as a routine step. install.pl gains a guard: running as
root against a site tree warns (or refuses unless --root-ok) and points at the
site-user path.

### Upgrades and channels

- The host tracks an apt repo (candidate: the Forgejo instance, which can
  serve deb repos alongside its OCI registry). Two suites: `stable` and
  `edge`, matching the existing release channels.
- Site copies remain per-site (as today - a site is self-contained). The host
  payload at /usr/share/lazysite is the upgrade source: `lazysite upgrade
  <site>` syncs a site from the payload IF the site's `update_channel` accepts
  the payload's channel; `lazysite upgrade --all` walks every registered site.
- Per-site timing: a site conf `update_policy: auto|manual` decides whether
  `--all` (cron-driven) touches it or the operator upgrades when they choose.
- **Security force**: a release marked security-critical in its manifest lets
  `lazysite upgrade --all --force-security` override channel and policy. This
  is the fleet answer to "with security issue, force upgrade is important".
- Site registry: provision records the docroot in
  `/etc/lazysite/sites.d/<domain>` so `--all`, fleet checks and fleet backups
  can enumerate sites without guessing paths.

### What stays out of scope here

- Multi-version engine trees on one host (kernel-style versioned packages).
  Rejected for now: per-site copies already give per-site versioning; the
  host payload is just the newest accepted source per channel.
- Moving sites to symlinked shared cgi-bin. A site stays self-contained so a
  host payload upgrade cannot break a site that has not opted in yet.

## Runtime dependency (2026-07-10)

SM142 (persistent runtime - per-site FastCGI pools) lands FIRST: the debs
package BOTH patterns - plain CGI as the zero-dependency fallback and the
FCGI pool as the production shape (systemd template unit lazysite@domain,
proxy_fcgi vhost config, socket conventions). Deciding the runtime before
packaging avoids re-packaging the vhost templates and a second fleet
migration.

## Increments

1. **debianize common**: debian/ packaging for lazysite-common (payload +
   `lazysite` CLI skeleton wrapping install.pl/check/users). Build via the
   existing release flow; artefacts to /srv/projects/packages/.
2. **provision-as-site-user**: the provision/upgrade verbs with the
   drop-privileges model + root guard in install.pl + site registry.
3. **channels/policy**: update_policy conf key, `upgrade --all`, security
   force; apt repo publication (stable/edge suites).
4. **hestia deb**: template/hook packaging on top of (2).
5. **check hardening** (parallel, small): lazysite-check re-runs checks after
   --fix (report currently shows the pre-fix snapshot - confusing in the
   field); add a manager-layout check (lazysite/manager/layout.tt present +
   CGI-readable - a root-run check misses this today, field-hit 2026-07-09);
   effective-access checks should evaluate as www-data (drop privileges or
   test modes), not as root.

## Open questions

- apt repo hosting and signing key management (Forgejo vs plain
  reprepro/aptly on the web host).
- Whether the Hestia integration is a hook script or a full Hestia app
  ("quick install app" template) - decide after increment 2 proves the
  provisioning model.
- Registry format for sites.d (one-line path vs small INI with channel/policy
  cached for fleet tooling).
