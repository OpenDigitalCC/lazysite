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
renewal or an alias change can leave a site the CGI cannot write to.

Since 0.11.2 the manager **says so on its next page load** rather than waiting
for a save to fail (SM270): a banner names the affected directories and the
repair command. That is a safety net, not the cure.

::: widebox
**The cure is to stop needing group write at all.** The permission fight exists
only under the no-suexec CGI, where the engine runs as `www-data` and therefore
needs the site's files to be group-writable - which is precisely the bit Hestia
strips. A site on the **per-site FastCGI pool** (SM142) runs as its OWN user:
the launcher binds the socket as root, chowns it, drops privileges to the site
user, and execs the processor. Owner-write is then enough, `2751` is harmless,
and `v-rebuild-web-domain` cannot break the site however often it runs.

So a site that keeps coming back with permission drift is telling you it should
be on a pool:

```bash
sudo systemctl enable --now lazysite@example.com
```

Identity comes from `/etc/lazysite/pools/example.com.conf` (`DOCROOT=`,
`USER=`); point the web server at the socket - see README.Debian and the
FastCGI pools section below. Sites left on the shared `www-data` CGI keep the
banner and `lazysite repair` as their answer.
:::

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

### The persistent runtime (lazysited)

Since 0.13.0 a site may run a second per-site process, the persistent runtime
(SM666): a supervisor and, under it, a scheduler that runs the engine's
maintenance jobs on a clock rather than on the back of a visitor's page view -
the hourly statistics rollup (which closes each day whether or not anyone opens
the Stats page, SM343) and the hourly sweep of expired sessions. It is
templated exactly like the pool:

```
/etc/lazysite/daemon/<domain>.conf     DOCROOT= and USER= (and ENGINE=, tarball hosts)
systemctl enable --now lazysited@<domain>.timer
```

On a **deb** host, `lazysite-hestia-domain add <user> <domain> --daemon` writes
the conf and enables the timer; `remove` retires it beside the pool. On a
**tarball** host the per-site deploy (`lazysite-hestia-deploy.sh`, root) does it
on every deploy and upgrade, automatically - conf with `ENGINE=<domain root>`
so the runtime runs the site's own `tools/` and `lib/`, unit and timer installed
into `/etc/systemd/system` from the release, timer enabled, a running runtime
restarted (SM757).

**`USER=` is the unix user the request path writes as - not the panel user
(SM760).** The runtime and the request path share one write plane: the CGI
writes the auth stores the runtime reads (`lazysite/auth/`), and the runtime
writes the pid, state and run records that Status reads. Both write their
files `0660`, so a file one of them creates is closed to the other unless they
are the same user. On the plain CGI flow that user is the web server's
(`www-data`); on a site served by the FastCGI pool it is the pool's `USER=`.
The deploy and `add --daemon` write it from that rule; if you write the conf by
hand, copy the user the site's requests run as. Status carries a `runtime_user`
check that compares the conf with the user Status itself runs as, and the run
record refuses by name (`cannot read lazysite/auth/groups-settings.json:
Permission denied`) rather than as a missing capability when they differ.
This was found on the first real run: every job refused as "does not hold
`run_jobs`" for an account that held it, because `www-data` had rewritten the
group settings and the panel user could no longer open them.

**Two switches, both needed.** The unit and its timer are yours (or the
deploy's); the `daemon` plugin is the site's, enabled by its sysop on the Plugin
Manager page and born disabled (ADR 0009). The manager has no root, so enabling
the plugin cannot start the service - the **timer** does, within five minutes:
while the service is not running it is started every five minutes, reads the
plugin, and either runs or exits at once (one short-lived process per five
minutes per disabled site; nothing while one runs). Pressing Enable runs the
Status check and shows beside the toggle whether the host has provisioned the
runtime and whether the job account is set and holds what the jobs need.
Disabling the plugin while the runtime is running stops it within ten seconds,
and the toggle line says whether it did ("the runtime is stopped", or "still
stopping (pid N)").
What it says about itself:

```bash
lazysited --docroot <docroot> --status      # desired / verdict / remedy per service
```

**Jobs run as an account, never as root or `system`.** The sysop names a
`daemon_job_user` in the plugin's config and gives that account the `run_jobs`
capability plus whatever the job needs (`analytics` for the rollup,
`manage_users` for the sweep) - a purpose account, not a person's. No account,
or one lacking a capability, means the job is refused with the reason in the
run record, `lazysite/daemon/scheduler-runs.json`, which is also where a job's
last outcome and counts are kept - and which Status carries as `runs`, since
no remote grant reaches `lazysite/daemon/` (SM759).

**Cost at rest.** Two Perl processes per site, about 10 MB PSS each after the
shared pages are apportioned (23 MB naive RSS); 300 instances is roughly 3 GB
PSS. The idle loops do no I/O. The rollup is about 0.5 s of CPU per site per
hour once warm (4-5 s once, at first enable, to ingest the existing log).

**Upgrades.** Since 0.13.1 the package runs `systemctl daemon-reload` on
install, upgrade and removal, so a changed unit file is seen at once (before
that, both units being templates, debhelper generated nothing - F8.4 in
`docs/review/0.13.1-daemon/`). A RUNNING instance keeps its old code until
you restart it; the package never restarts one for you, because which sites
restart, and when, is your call. Restart instances after an engine upgrade the
way you restart pools:

```bash
systemctl restart lazysited@<domain>
```

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
- **Start page (SM724):** where an account lands when it signs in without a
  destination - a manager page it can reach, or a chosen page on a domain this
  instance serves. A user sets their own from their name in the manager header
  (the account sheet); a user manager sets anyone's from the Users page or
  `lazysite-users set <user> start_page manager:files`. Unset lands on the
  manager with the account sheet open; a start page that stops being reachable
  lands there too, flagged, rather than on a refusal. A link followed to sign in
  still wins.
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
