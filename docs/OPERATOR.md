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

**Update channel.** Each site has an `update_channel`, and it names the
**minimum maturity the site will accept**. The ladder is
`edge` < `beta` < `stable` < `certified`:

```datatable
columns: Setting | Accepts
widths: 3.0cm | X
bold: 1
tone: medium
---
`edge` | every release, including pre-release builds
`beta` | beta and above; skips edge
`stable` | stable and certified builds - supported software
`certified` | certified builds only: stable-quality releases whose compliance records (signed declaration, restore rehearsal, registers) were walked before the cut (ADR 0010)
---
```

::: widebox
**The default is `stable`, not `edge`** - and this paragraph said the
opposite until 2026-08-19. SM356 changed it: the default used to fail
OPEN, accepting every build when the conf could not be read, when the
line was missing, and when the value was unrecognised - so
`update_channel: stabel` silently meant *the most permissive setting
available*. It now falls to the most restrictive rung, and an
unrecognised value is reported rather than quietly corrected.

The consequence for a rollout: **a site with no `update_channel` line
refuses a beta or edge build.** Before assuming a pre-release reaches
the fleet, check what each site actually accepts rather than what the
default used to be.
:::

Set or move it without hand-editing the conf, and loop over docroots for
a whole fleet:

```bash
install.pl --channel stable --docroot <docroot>   # customer rollout
install.pl --channel beta   --docroot <docroot>   # bedded-in candidate
install.pl --channel edge   --docroot <docroot>   # every build
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

### Repairing permissions and ownership - the one way

**`lazysite repair`.** It runs the doctor, applies its safe fixes, then checks
again and reports the state AFTER the repair, per site.

```bash
sudo lazysite repair --all --dry-run           # preview every site, change nothing
sudo lazysite repair --all                     # apply
sudo lazysite repair --domain example.com      # one site, by name
```

It finds the sites itself: the registry at `/etc/lazysite/sites.d/` on a
deb-managed host, falling back to Hestia's own site list when that registry does
not exist (SM329) - which is every tarball deployment, since `provision` is what
writes the registry and the tarball path never runs it. Root is needed for both:
the chown half of the repair, and the Hestia list.

From an unpacked tarball, where `/usr/bin/lazysite` is not installed:

```bash
sudo perl /path/to/lazysite-<version>/tools/lazysite-cli.pl repair --all
```

::: widebox
**There are several doors into this and only one is worth remembering.**
`lazysite-check.pl --docroot ... --fix` is the engine - correct, but per-site and
you supply the paths. `lazysite-fix-perms.pl` is a front-end to the same engine
with no fleet addressing. `lazysite check --all --fix` works by pass-through, but
`check` is the verb that REPORTS; `repair` is the one that fixes and then
re-checks, which is what you want after an upgrade. They are one implementation
behind four entrances, so none of them disagree - but use `repair`.
:::

**When to run it.** After any upgrade, and after anything that rebuilds a vhost
through the control panel. Hestia's `v-rebuild-web-domain` re-applies its own
docroot permissions (`2751`: setgid, no group write) and a rebuild driven from
the panel never reaches the lazysite deploy that repairs that - so an SSL
renewal or an alias change can leave a site the CGI cannot write to, and nothing
says so until the manager fails to save.

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
  per-user from each account's card. Shell user management is on the trail
  too (origin `cli`, attributed to the invoking system user);
  installs/upgrades appear as origin `install`.
- Optional syslog forwarding of the audit trail and/or diagnostics for an
  external collector: the **Logging & forwarding** plugin
  (`forward_audit` / `forward_diagnostics` / `syslog_facility`).
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
| `/dav` 404s every method | WebDAV disabled site-wide - Config -> Services, or `webdav_enabled: yes`. |
| connector never asks for the connect code | the OAuth client is set to CIMD (use "register one automatically"), or `oauth_enabled` is off - see `/docs/ai-connector-setup`. |
| add-user "Permission denied" | auth files not group-writable - `sudo lazysite repair --domain <site>`. |
| site shows Hestia placeholder | stray `index.html` shadowing `index.md` - the deploy removes it. |
| login 500 | `lazysite/auth` not writable by www-data (the `.secret` can't be minted) - `sudo lazysite repair --domain <site>`. |

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
