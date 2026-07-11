# SM139 - Packaged distribution: common .deb + environment .debs + unprivileged provisioning

Status: in progress - increments 1-5 built (design agreed in principle
2026-07-09); apt repo publication is the remaining open item
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
: Hestia integration: web templates + a hook-shaped command so "add
  lazysite to a domain" is one root command; knows Hestia's user/group
  layout and drives provisioning correctly. As built (increment 4) it
  depends directly on lazysite-common and carries its own Apache vhost
  templates - the standalone apache/nginx glue packages below have not
  been built yet, and Hestia pins the web server anyway.

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

1. **debianize common** *(built, `f66d5cc`)*: debian/ packaging for
   lazysite-common (payload + `lazysite` CLI skeleton wrapping
   install.pl/check/users). Build via the existing release flow; artefacts
   to dist/.
2. **provision-as-site-user** *(built, `f66d5cc`)*: the provision/upgrade
   verbs with the drop-privileges model + root guard in install.pl + site
   registry.
3. **channels/policy** *(built 2026-07-10)*: `update_policy: auto|manual`
   conf key (default manual; setter `install.pl --policy`, audited as
   `policy-set`; cached as `policy=` in the registry, seeded by
   `provision --policy`). `lazysite upgrade --all` skips manual-policy
   sites (logged per site) and lets install.pl's existing exit-3 channel
   gate decide auto-policy sites; `--force` overrides both gates.
   `--force-security` also overrides both but is honoured only when the
   payload manifest declares `"security_critical": true`
   (build-manifest.pl `--security-critical`) - refused with a clear
   message otherwise. New `lazysite sites` verb lists the fleet
   (owner/channel/policy/installed version/docroot). Tested in
   t/tools/29-cli-fleet.t. Apt repo publication (stable/edge suites)
   remains open - see the hosting/signing question below.
4. **hestia deb** *(built 2026-07-10)*: lazysite-hestia binary package
   (Arch: all; Depends: lazysite-common (= source version), sudo) from
   the same debian/ source. Apache web templates for BOTH runtime
   patterns at /usr/share/lazysite-hestia/templates (lazysite-cgi =
   FallbackResource through the auth wrapper; lazysite-fcgi = visitor
   pages proxied to unix:/run/lazysite/&lt;domain&gt;.sock via
   mod_proxy_fcgi, session-cookie/auth/manager traffic kept on the CGI
   path) + /usr/bin/lazysite-hestia-domain (add/remove/list): root-run
   panel integrator that prepares the locked domain root as root,
   drops to the panel user for `lazysite provision`, writes the
   registry entry, and with --fcgi writes the pool conf and enables
   lazysite@&lt;domain&gt;. remove stops/deregisters, never deletes the
   docroot. Supersedes the hand-run installers/hestia scripts
   (runbook rewritten around the debs; old scripts kept in-tree for
   existing deployments). Tested in t/tools/30-hestia-pkg.t.
5. **check hardening** *(built 2026-07-10)* (parallel, small):
   lazysite-check re-runs the checks after --fix applied anything, so the
   report reflects the post-fix state (the pre-fix snapshot confused
   operators in the field); manager-layout probe when the manager is
   enabled (lazysite/manager/layout.tt present + readable by the CGI
   identity, FAIL names the fallback-layout / stuck-at-Loading symptom -
   field-hit 2026-07-09); effective-access checks (conf readability,
   cgi-bin executability, secrets) evaluate as the CGI via ownership+mode
   arithmetic rather than -r/-w/-x (root bypasses DAC, so root-run checks
   passed on www-data-only failures), plus a group-execute traversal check
   on lazysite/, lazysite/manager/ and lazysite/auth/. Tested in
   t/tools/04-check.t.

## Open questions

- apt repo hosting and signing key management (Forgejo vs plain
  reprepro/aptly on the web host).
- ~~Whether the Hestia integration is a hook script or a full Hestia app
  ("quick install app" template)~~ DECIDED (2026-07-10, increment 4):
  **hook-shaped command** (lazysite-hestia-domain). The command shape
  needs nothing from Hestia's app framework, is scriptable/cron-able,
  and exercises the increment-2 provisioning model directly; a
  panel-native "quick install app" remains a possible future layer that
  would only wrap the same command.
- Registry format for sites.d (one-line path vs small INI with channel/policy
  cached for fleet tooling).
