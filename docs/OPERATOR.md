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

One site:

```bash
sudo bash installers/hestia/lazysite-hestia-deploy.sh <user> <domain> <stage>
```

Every lazysite site on the host at once (discovers them by the
`.install-state.json` marker):

```bash
sudo bash installers/hestia/lazysite-hestia-update-all.sh --list   # preview
sudo bash installers/hestia/lazysite-hestia-update-all.sh          # code+content
sudo bash installers/hestia/lazysite-hestia-update-all.sh --templates  # also refresh the vhost
```

`--templates` re-applies the shared `lazysite-app` vhost template - use it when
a release notes a vhost change (e.g. a new `FilesMatch`). Upgrades preserve
edited content (the seed/conffile model) and skip unwritable files non-fatally.

## Logs and audit

- Application logs: `lazysite/logs/`.
- Manager audit trail (who/what/when/where): the manager **Audit** page, and
  per-user from each account's card.
- Apache logs: the vhost's usual access/error logs.

## Routine tasks

- **Users/credentials:** the manager Users page, or
  `tools/lazysite-users.pl` on the shell. The operator never sets a user's
  password - issue a setup link or token; the user provisions their own.
- **Themes/layouts:** activate globally from the manager (or an agent does it
  over the control API). Re-activate after editing a theme.
- **Cache:** manager **Cache → Clear** (partial-safe - only generated HTML).
- **Forms:** submissions land in `lazysite/forms/submissions/`; SMTP delivery
  needs `lazysite/forms/smtp.conf` (operator-only - it holds credentials).

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
