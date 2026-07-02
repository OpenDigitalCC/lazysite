# lazysite - Implementor guide

For someone **installing or integrating** lazysite. The authoritative, worked
procedure (HestiaCP) is
[installers/hestia/INSTALL-RUNBOOK.md](../installers/hestia/INSTALL-RUNBOOK.md);
this is the map. For running it afterwards see [OPERATOR.md](OPERATOR.md).

## Requirements

- A **CGI-capable web server**. Apache is first-class: lazysite relies on
  `FallbackResource`, `ScriptAlias`, `mod_headers` (the `RequestHeader unset
  X-Remote-*` trust-strip), `<FilesMatch>`, and `+ExecCGI`. nginx needs a CGI
  bridge and is not the supported path.
- **Perl** (5.x core). Optional: Template Toolkit (theming), Archive::Zip
  (layout install), DB_File (rate limiting). All declared in
  `dist/config/sbom-deps.json`.

## Install model

`install.pl` deploys files per `dist/config/classification.json`:

- **code** bucket - always overwritten on upgrade (scripts, manager UI, docs).
- **seed** bucket - conffile model: overwritten only if unchanged since the
  last install, otherwise preserved (your content, config).

It records per-file SHAs in `lazysite/.install-state.json`, so upgrades never
clobber edited content and an unwritable file is skipped non-fatally.

## Deploying (HestiaCP, one command)

```bash
sudo bash installers/hestia/lazysite-hestia-deploy.sh <user> <domain> <stage-dir>
```

This applies the `lazysite-app` web template (the **cookie-auth wrapper** variant
- not the basic `lazysite.tpl`), runs `install.pl` as the domain user, and sets
the permissions a www-data CGI needs (`chown -R user:www-data`, setgid `2775`
dirs, `2770` on `lazysite/auth`). See the runbook for the one-time template
install and `a2enmod headers`.

## First-run configuration

In `lazysite/lazysite.conf` (or the manager Config page):

- Manager access is the `ui` **capability on a group** (SM095): bootstrap with
  `lazysite-users.pl setup-manager`, which creates the admin group + user; grant
  `ui` to further groups on the manager Groups page. (The legacy
  `manager_groups:` conf key still works as a backend fallback but is no longer
  edited in the UI; with neither set, an unsecured/dev site treats any
  authenticated user as a manager.)
- `webdav_enabled: yes` - **off by default**; `/dav` returns 404 to every
  method until set (by design). The `webdav` capability is then granted
  per-group like any other.
- `site_name`, `layout`, `theme` - activate a theme globally.
- Set the manager password: `lazysite-users.pl passwd manager '<pass>'`.

## Integrating an AI publishing partner

Create an account, issue an `lzp_` pairing key, hand over the onboarding brief.
The partner exchanges it for an `lzs_` token and publishes over `/dav` + the
control API within its grant. The trust model, scope and deny-set are enforced
server-side; see [SECURITY.md](../SECURITY.md) and the publishing briefing.
