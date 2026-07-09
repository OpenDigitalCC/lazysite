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
  `dist/config/sbom-deps.json`; the packaged list (Debian names + purpose) is
  at [docs/reference/host-dependencies.md](reference/host-dependencies.md), and
  `lazysite-check.pl --dependencies` reports which are present on a given host
  and the install line for anything missing.

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
  `ui` to further groups on the manager Groups page. (SM138: the legacy
  `manager_groups:` conf key is retired - on upgrade any group it named receives
  its capabilities explicitly and the conf line is removed. When NO group grants
  manager access, an unsecured/dev site treats any authenticated user as a
  manager.)
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

A connecting agent should learn what it may do from the **capability map** rather
than by trial and error: the MCP `describe_capabilities` tool (or the control-API
`describe-capabilities` action) returns the channels, what each capability
unlocks, task recipes, the engine-owned paths not to touch, and the account's own
grant. The same model, for humans, is at
[docs/reference/capability-map.md](reference/capability-map.md) with copy-pasteable
[quickstarts](reference/quickstarts.md). Grant a partner the channel it uses
(`api` for the control API, `mcp` for the connector, `webdav` for `/dav`) plus the
action capabilities for its role - the standard onboarding does this.
