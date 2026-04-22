# Upgrade notes

## 0.2.x to 0.3.0

The installer is now upgrade-aware. This is the first version
with safe in-place upgrades; you can re-run `install.sh` to
pick up future releases without losing site content.

### What this enables

- Seed files you have edited (starter pages, your custom docs,
  registry templates) are preserved across upgrades.
- Code files (processor, plugins, manager UI, system theme)
  are overwritten with each new release.
- Files removed in new versions are cleaned up only if you
  haven't edited them; edited orphans stay and produce a
  warning.
- Pre-upgrade backups accumulate under
  `{docroot}/lazysite/backups/`, retained per
  `backup_retention` in `lazysite.conf` (default 3; 0 = keep
  all).
- `install.sh --dry-run` shows the full upgrade plan without
  modifying anything.

### What does NOT get migrated

Installs created with 0.1.x or 0.2.x pre-dating the 0.3.0
installer do not have `.install-state.json`. The installer
treats them as fresh installs: it walks the manifest and
skips-if-present, which is the old behaviour. The first
post-0.3.0 run establishes `.install-state.json` for future
upgrades. Effectively, 0.3.0 is where upgrade-tracking begins.
Plan to back up your docroot before the first 0.3.0 install
on an existing deployment.

### If upgrade goes wrong

Every upgrade creates a backup first. To restore:

```bash
bash install.sh --docroot /path/to/public_html --restore
```

To list available backups:

```bash
bash install.sh --docroot /path/to/public_html --list-backups
```

To restore a specific backup:

```bash
bash install.sh --docroot /path/to/public_html --restore --backup PATH
```

Restore does not touch runtime state (auth users, cache,
logs). It invalidates the rendered HTML cache afterwards so
stale pages don't linger.

### No default layout or theme ships

0.3.0 ships no layout or theme content of its own. A fresh
install has no `lazysite/layouts/NAME/layout.tt`, and the
processor falls back to a built-in template until one is
installed. Install a layout + theme via the manager UI at
`/manager/themes` > "Install from Releases" (the configured
`layouts_repo` default is `OpenDigitalCC/lazysite-layouts`),
or drop a layout directory in manually.

### New files installed

`install.sh` now installs:

- `install.pl` at the repo root (the real installer; the
  shell script is a thin wrapper).

### No change for fresh installs

First-time installs work the same as before.
`.install-state.json` is created automatically on first run.

## 0.1.0 to 0.2.0

Breaking changes in this release. Read the whole file before
upgrading a production install.

### Plugin URLs changed

Plugins moved from `/cgi-bin/lazysite-*.pl` to `/cgi-bin/*.pl`:

- `/cgi-bin/lazysite-form-handler.pl` -> `/cgi-bin/form-handler.pl`
- `/cgi-bin/lazysite-payment-demo.pl` -> `/cgi-bin/payment-demo.pl`

Update any external integrations pointing at these URLs:

- Web form `action=` attributes in custom pages
- Webhook URLs in `handlers.conf`
- External systems POSTing to `form-handler`
- Payment flow URLs

`form-smtp` is not a URL endpoint (it runs as a subprocess of
`form-handler`), so nothing to update there.

### Plugin source locations changed

Plugin scripts moved from the repo root (and `tools/`) to
`plugins/`, dropping the `lazysite-` prefix:

- `lazysite-form-handler.pl`   -> `plugins/form-handler.pl`
- `lazysite-form-smtp.pl`      -> `plugins/form-smtp.pl`
- `lazysite-payment-demo.pl`   -> `plugins/payment-demo.pl`
- `lazysite-log.pl`            -> `plugins/log.pl`
- `tools/lazysite-audit.pl`    -> `plugins/audit.pl`

Core scripts keep their `lazysite-` prefix at repo root:

- `lazysite-processor.pl`
- `lazysite-auth.pl`
- `lazysite-manager-api.pl`

`install.sh` now places plugins under `{docroot}/../plugins/`
and symlinks `form-handler.pl` and `payment-demo.pl` into
`cgi-bin/` for Apache routing. The dev server
(`tools/lazysite-server.pl`) discovers both locations.

### Plugin enable-list entries become stale

Your installed `lazysite.conf` has `plugins:` entries referencing
the old plugin paths, for example:

    plugins:
      - cgi-bin/lazysite-form-handler.pl
      - tools/lazysite-audit.pl

After upgrading to 0.2.0, these paths no longer resolve. The
manager UI will treat the plugins as disabled, even though the
underlying scripts are installed. Form processing, audit runs, and
any other affected features stop working silently.

**To fix:**

**Option 1 - via the manager UI.** Visit `/manager/plugins` and
toggle each plugin off then on. The new paths are written to
`lazysite.conf` in the new format.

**Option 2 - hand-edit lazysite.conf.** Replace old paths with
new ones:

    cgi-bin/lazysite-form-handler.pl  -> plugins/form-handler.pl
    cgi-bin/lazysite-form-smtp.pl     -> plugins/form-smtp.pl
    tools/lazysite-audit.pl           -> plugins/audit.pl
    lazysite-log.pl                   -> plugins/log.pl

Leave `lazysite-auth.pl` alone - it stays at repo root and keeps
its old entry.

This migration will be automatic in 0.3.0 when the upgrade-safe
installer lands (D021c).

### Upgrade procedure

1. Review external integrations (webhooks, custom form actions,
   payment flows). Update any URLs that point at the old
   `/cgi-bin/lazysite-*.pl` paths.
2. Take a backup of your site. (The upgrade-safe installer arrives
   in 0.3.0; for now, backup is manual.)
3. Extract `lazysite-0.2.0.tar.gz` and run `install.sh` with the
   same `--docroot` and `--cgibin` you used for 0.1.0.
4. The installer places new plugins under
   `{docroot}/../plugins/`. Old plugin files left over from 0.1.0
   in `/cgi-bin/` or `{docroot}/../` can be removed manually once
   you have confirmed the new layout works.
5. Reconcile `lazysite.conf` `plugins:` entries per the previous
   section.
6. Restart Apache (or reload the config) to ensure routing
   changes take effect.

### New files installed

`install.sh` now catches up with files that were in the release
manifest but previously not installed by the installer:

- `starter/docs/features/` subtree (authoring, configuration, and
  development feature docs) under `{docroot}/docs/features/`
- `tools/lazysite-server.pl` (dev/evaluation server) and
  `tools/build-static.sh` (static site export) under
  `{docroot}/../tools/`
- `lazysite.conf.example` and `nav.conf.example` as reference
  files under `{docroot}/lazysite/`
- `users.example` and `groups.example` under
  `{docroot}/lazysite/auth/` as references, and as seed sources
  for `users` / `groups` on fresh installs
