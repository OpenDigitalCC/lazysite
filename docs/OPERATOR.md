# lazysite - Operator guide

For someone **running lazysite in production**. Install/first-run is in
[IMPLEMENTOR.md](IMPLEMENTOR.md) and the
[HestiaCP runbook](../installers/hestia/INSTALL-RUNBOOK.md); this is the
day-to-day runbook.

## Layout on disk (per site)

```
<docroot>/                      content (.md / .html cache / assets)
<docroot>/cgi-bin/              the CGI scripts
<docroot>/lazysite/             state - not web-served
  auth/      users, groups, user-settings.json, .secret, locks (2770)
  cache/     generated HTML
  logs/      application logs
  forms/     form configs + submissions (secrets denied to agents)
  layouts/   layouts + nested themes
  .install-state.json           per-file SHAs (upgrade tracking)
```

## Upgrading

On deb-managed hosts (`lazysite-common` installed - the packaged flow since
0.7.2), one site, **as the site user** (the CLI refuses to run `provision` or
a single-site `upgrade` as root - no root writes into site trees):

```bash
sudo -u <siteuser> lazysite upgrade --docroot <docroot>   # --cgibin from the registry
```

Legacy tarball-era Hestia hosts still use the superseded hand-run scripts
(kept in-tree for existing deployments only - see the runbook's appendix):

```bash
sudo bash installers/hestia/lazysite-hestia-deploy.sh <user> <domain> <stage>
sudo bash installers/hestia/lazysite-hestia-update-all.sh --list   # fleet preview
sudo bash installers/hestia/lazysite-hestia-update-all.sh          # fleet code+content
```

Upgrades preserve edited content (the seed/conffile model) and skip unwritable
files non-fatally.

**Update channel.** Each site has an `update_channel` (`edge` default, or
`stable`); a `stable` site skips out-of-channel (edge) builds. Set or move it
without hand-editing the conf, and loop over docroots for a whole fleet:

```bash
install.pl --channel stable --docroot <docroot>   # pin to stable (customer rollout)
install.pl --channel edge   --docroot <docroot>   # back to edge
```

Force one specific out-of-channel upgrade through the policy with `--force`
(audited as `upgrade-forced`).

### Fleet upgrades (the `lazysite` CLI)

Hosts with the `lazysite-common` deb (SM139) manage sites through the site
registry (`/etc/lazysite/sites.d/`, written by `lazysite provision`):

```bash
lazysite sites                          # the fleet: owner/channel/policy/version
sudo lazysite upgrade --all             # upgrade every opted-in site
sudo lazysite upgrade --all --force     # override channel AND policy
sudo lazysite upgrade --all --force-security   # security releases only (below)
```

Two per-site keys in `lazysite.conf` gate `upgrade --all`:

- `update_policy: auto|manual` (default `manual`) - whether the fleet run
  (typically cron-driven) touches the site at all. `manual` sites are skipped
  and logged; upgrade them individually when you choose. Set it with
  `install.pl --policy auto --docroot <docroot>` (audited as `policy-set`).
- `update_channel` (above) - an `auto` site still takes only a payload its
  channel accepts; the skip is the installer's usual clean exit-3, audited.

**Security releases.** A release built with
`tools/build-manifest.pl --security-critical` carries
`"security_critical": true` in its manifest. Only then does
`upgrade --all --force-security` work - it overrides both channel and policy
fleet-wide. Against a payload that does not declare it, the command refuses
before touching any site: the override is only as strong as the release's
own declaration.

### FastCGI pools

Sites on the packaged FastCGI pattern (SM142) run a persistent per-site worker
pool: `lazysite@<domain>.service`, identity from
`/etc/lazysite/pools/<domain>.conf` (`DOCROOT=`, `USER=`, and optionally
`GROUP=`, `WORKERS=`, `MAX_REQUESTS=`, `SOCKET=`), socket at
`/run/lazysite/<domain>.sock`. On Hestia,
`lazysite-hestia-domain add <user> <domain> --fcgi` writes the config and
enables the unit in one step. A pool picks up upgraded site code (or an edited
pool conf) on restart:

```bash
systemctl restart lazysite@<domain>
```

The auth wrapper, manager traffic and all cgi-bin/dav endpoints stay on the
plain-CGI path; only anonymous visitor pages are pooled.

## Logs and audit

- Application logs: `lazysite/logs/`.
- Manager audit trail (who/what/when/where): the manager **Audit** page, and
  per-user from each account's card.
- Apache logs: the vhost's usual access/error logs.

## Routine tasks

- **Users/credentials:** the manager Users page, or
  `tools/lazysite-users.pl` on the shell. The operator never sets a user's
  password - issue a setup link or token; the user provisions their own.
- **Sessions:** the manager **Sessions** page (needs the Users & groups
  permission) lists live sessions (user, signed in, IP, device) and signs out
  one session or all of a user's sessions; rotating the signing secret (Users
  page, "log out all users") remains the everyone-at-once option.
- **Themes/layouts:** activate globally from the manager (or an agent does it
  over the control API). Re-activate after editing a theme.
- **Cache:** manager **Cache → Clear** (partial-safe - only generated HTML).
- **Forms:** submissions land in `lazysite/forms/submissions/`; SMTP delivery
  needs `lazysite/forms/smtp.conf` (operator-only - it holds credentials).
- **Scanner blocking:** the bad-URL auto-blocker (on by default) blocks a source
  IP after repeated scanner-probe hits; review and unblock on the manager **Stats**
  page, and tune the threshold/window on **Plugin Config**.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `/dav` 404s every method | WebDAV disabled site-wide (`webdav_enabled: yes`). |
| add-user "Permission denied" | auth files not group-writable; re-deploy or `chmod g+w lazysite/auth/*`. |
| site shows Hestia placeholder | stray `index.html` shadowing `index.md` - the deploy removes it. |
| login 500 | `lazysite/auth` not writable by www-data (the `.secret` can't be minted). |

## Backups

Back up the whole `<docroot>` tree; `lazysite/` carries all state (users,
content provenance, ACLs, config). `install.pl` also writes a timestamped
backup before each upgrade.

The manager **Backups** page offers two typed kinds:

- **Content** backups - a snapshot of the served content, restorable from the
  page (a prerestore safety snapshot is taken first).
- **Full-system** backups - the whole site including config, accounts and
  themes/layouts. These carry the auth secrets, so they are download-only in the
  manager and restored by a system user from the shell:

  ```bash
  install.pl --restore-full <file>.tar.gz --docroot <docroot> [--domain <new-domain>]
  ```

  `--domain` rewrites the site's domain on restore - the path for **migrating a
  site to another domain** (build on a temporary domain, then move content, config
  and accounts to the final one), as well as disaster recovery.
