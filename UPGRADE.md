# Upgrade notes

## Upgrading to 0.10.15 from 0.10.10-0.10.14 (READ THIS ONE)

The package upgrade does the code. **Four things it cannot do**, and the
order matters.

### 1. Re-apply access rules, AFTER the upgrade

From 0.10.8 protecting content MOVES it out of the served tree - but
only on the act of protecting. Any section protected on an earlier
version still has its files in the document root, with the rule honoured
for pages and the files public.

```bash
lazysite acl reapply --docroot <docroot>
```

After the upgrade, never before: it re-issues stored rules through the
new code. It changes no rule. `NOT MOVED: <path>` in the output means
the rule was stored and nothing moved, which is the condition it exists
to find.

### 2. The proxy template, which a package cannot deliver

`lazysite-proxy` is a Hestia template. **A package upgrade does not
install or update one**, and 0.10.15 corrects a defect in it (SM374)
that returns **421 on every request** to a TLS domain.

::: widebox
**While the host's copy is stale the failure is identical to the bug.**
An operator who applies the fix, sees 421, and concludes the fix does
not work has been misled by their own template directory. Confirm the
copy on the host is the new one before drawing any conclusion from a
421.
:::

```bash
v-change-web-domain-proxy-tpl <user> <domain> lazysite-proxy
```

Test on the **body**, not the status: without a correct `Host` the
backend serves its default vhost with a 200, so a status check cannot
say which site answered.

### 3. The private store, if it does not exist yet

Creating it is a root action. `lazysite-check` reports whether the
engine can write to it; if the store is missing on a site that protects
anything, create it before re-applying rules.

### 4. Verify from outside, as the site user

```bash
lazysite check --check-acl https://<domain>
```

**Not as root.** The probe protects a fixture to measure it, and doing
that as root would leave root-owned files in the site tree - so it
declines and says so (SM377). The reason it gives is the one to act on;
the summary no longer overwrites it with a guess (SM385).

### Effective permissions widen if you are coming from 0.9.x

This has its own heading because it is a change of **who can read what**,
not a feature.

An `@group` entry in an ACL grants access to the members of that group.
Until SM288, MCP and the control API **discarded an account's groups**,
so those entries were silently inert on two of the three channels.
WebDAV honoured them; the others did not.

::: widebox
**Nobody gains groups here.** Partners already had them; two channels
were throwing them away. What changes is that an `@group` entry which
has been doing nothing on MCP starts doing what it says.
:::

Before upgrading a site that uses `@group` entries, see exactly who is
affected:

```bash
lazysite acl group-reach --docroot <docroot>
```

It lists each `@group` entry, the paths that grant it, and **every
account it reaches - including through nested groups**. Nested is the
case worth having: an account that reaches a group only by nesting is
precisely the one a quick look at the members list would miss.

If the report names an account you did not expect to have access,
resolve it before upgrading rather than after.

### What changed that you will see

- **A Content-Security-Policy now ships**, `report-only` by default.
  `csp: enforce | report-only | off` in `lazysite.conf`. **Do not set
  `enforce` yet** - the manager's controls use inline handlers a CSP
  hash cannot cover, so the manager is held at report-only regardless
  until they are converted.
- **Engine-served statics revalidate** rather than caching for a decade
  (SM387), and now carry an ETag so revalidation costs a 304 rather than
  a re-download (SM388). The ten-year cache was a property of the
  front-end fast path, not of lazysite.
- **402 and 403 pages** carry the full header set and resolve their own
  domain's content root - on a multi-domain instance they were rendering
  into the primary's docroot.
- **A backup of a live site no longer fails** because a visitor arrived
  mid-snapshot (SM381).

## Upgrading to 0.10.10 from 0.10.0, 0.10.8 or 0.10.9

The fleet spans **0.10.0** (stable) and the edge line, and every one of them
needs the same operator action after upgrading. It is not delivered by the
package.

### Why an upgrade alone is not enough

From 0.10.8, protecting content **moves it out of the document root** into a
private store beside it, so that a front end which serves files without asking
the engine cannot reach protected bytes. That was the structural answer to
SM248, SM268 H17 and SM283.

The move happens **on the act of protecting**. It is not a migration, and no
upgrade performs it retrospectively. So:

```datatable
columns: If the site is on | Then after upgrading to 0.10.10
widths: 3.4cm | X
bold: 1
tone: medium
text: 2
---
0.10.0 (stable) | Every section ever protected still has its FILES in the document root. The rule is stored and honoured for pages; the files are reachable by anyone who knows the path on a front end that answers statics itself. Measured on a real upgraded site: 19 of 25 extensions still served byte-identically to an anonymous request.
0.10.8 (edge) | The same, for anything protected before 0.10.8 - AND anything protected ON 0.10.8 may be in that state too, because SM296 could crash the move after the rule was saved, leaving the content stored-as-protected and still served with no audit line.
0.10.9 (edge) | The same, if the sweep was run and reported success while moving nothing. Until 0.10.10 a re-apply that stored the rule and moved no files counted as "re-applied" and exited 0, so a fleet sweep could report every site done having achieved nothing. **Run it again on 0.10.10 and read the new count.**
```

Both are repaired by the same action, because both are "the rule is right and
the bytes are in the wrong place".

### What 0.10.10 changes about this

Three things, all of which make the SAME action more likely to actually work:

- **The store gets created.** The sweep needs the private store, which is a
  SIBLING of the document root - so repairing the docroot never reached it, and
  a site with a perfectly repaired `public_html` could still move nothing.
  `lazysite check --fix`, run as root, now creates it. See below.
- **A sweep that moves nothing says so.** It is counted as `moved nothing`
  rather than `re-applied`, the cause is named once, and the command exits
  non-zero. On 0.10.9 and earlier it reported success.
- **The rollout checks from OUTSIDE afterwards.** Every run now probes each site
  anonymously and reports whether the front end honoured the rule, because the
  engine's report and the front end's behaviour are different claims and have
  disagreed three times. A site it could not measure is reported as `not
  confirmed` rather than as passing.

### The action

**Re-apply every stored rule.** This re-issues each rule with the values already
in the store - it grants nothing, revokes nothing, and changes no rule. What
changes is where the files live.

Per site:

```bash
# see what would happen (dry run - this is the default)
lazysite acl reapply --docroot /path/to/public_html --actor local

# do it
lazysite acl reapply --docroot /path/to/public_html --actor local --apply
```

Across a Hestia fleet, as part of the rollout:

```bash
bash /tmp/lazysite-0.10.10/installers/hestia/lazysite-hestia-update-all.sh \
     --reapply-acls
```

The sweep runs only on sites that actually upgraded - a site skipped by its
update channel is still on its old version - and runs as each site's own user,
never as root.

::: widebox
**Order matters: upgrade first, then sweep.** The re-apply is the operation
SM296 broke. On 0.10.8 it is the thing that crashes, so running it before the
upgrade repairs nothing and reports failures. `--reapply-acls` sweeps after the
deploy step for exactly this reason.
:::

### The sweep needs the private store to exist

The store is `<docroot>-lazysite-private` - a **sibling** of the document root,
not a directory inside it. Creating it needs write access on the docroot's
*parent*, which on the Hestia layout is the domain folder.

**Repairing the document root does not fix this.** They are different
directories, and a site can have a perfectly repaired `public_html` where the
sweep still moves nothing. That happened on a live instance in August 2026:
`MKCOL`, `PUT`, overwrite and `DELETE` at the site root all worked, and
protecting a folder still left every file public and anonymously reachable.

```bash
lazysite check --docroot /path/to/public_html          # names the store, owner, mode
sudo lazysite check --docroot /path/to/public_html --fix   # creates it
```

`--fix` creates the store owned by the site user, mode 2770. It deliberately
does **not** make the parent directory group-writable: that parent also holds
`cgi-bin`, and write permission on a directory is permission to rename its
entries, so the wider repair would open a larger hole than the one being closed.

From 0.10.10 the sweep reports this rather than hiding it. A re-apply that stores
the rule and moves nothing counts as `moved nothing`, not as `re-applied`, and
the command exits non-zero - so a fleet sweep that achieved nothing can no longer
report success.

### Verify from outside

Do not take the sweep's own word for it. The engine's report and the front end's
behaviour are different claims, and SM283 was the case where they disagreed.

**From 0.10.10 the fleet rollout does this for you**, per site, at the end of
every run - reporting `verified`, `exposed` and `not confirmed` separately, and
exiting non-zero on an exposure. Run it by hand for a single site, or to re-check
after repairing one:

```bash
lazysite check --check-acl https://<domain>/
```

That gates a probe folder against a principal which cannot exist and fetches it
anonymously under several extensions, with a public control of the same type
alongside each - so a refusal that happens because the front end cannot read the
file is distinguishable from a refusal that is the access rule working.

### Also outstanding from 0.10.7, on Hestia

SM283's remedy is an nginx **proxy template**, and it is likewise not delivered
by a package upgrade: the template must be staged and each domain moved onto it.

```bash
bash /tmp/lazysite-0.10.10/installers/hestia/lazysite-hestia-update-all.sh \
     --proxy --reapply-acls
```

Check whether a domain has it with no credentials:

```bash
curl -sI https://<domain>/ | grep -i X-Lazysite-Front
```

A domain with an ACL store and no `X-Lazysite-Front` header is on a stock proxy
and is the SM283 shape. `lazysite-hestia-list.sh` flags those as
`ACL-BYPASSED-BY-PROXY(SM283)`.

### Optional, and separate

`lazysite migrate-engine-tree --apply` moves the `lazysite/` engine tree out of
the document root (SM293). Dry-run by default, reversible with `--back`, and
gated by `--min-version`. It is unrelated to the re-apply sweep and can be done
whenever.

## manager_groups retired (SM138)

The legacy `manager_groups:` key in `lazysite.conf` is retired. Manager access
is granted by **groups**: any group carrying the `ui` capability (manager UI) or
`manage_users` (operator powers), managed on the manager **Groups** page.

**Migration is automatic.** On the first settings read after upgrade, any group
the conf key named receives the full manager grant explicitly (every capability
except the remote `api`/`mcp` channels - manager groups are interactive-only),
and the `manager_groups:` line is removed from `lazysite.conf`. Effective access
is unchanged: those groups had unrestricted operator access through the fallback
already. No operator action is needed; a lingering line (e.g. an unwritable
conf) is simply ignored.

If **no** group grants manager access at all, the site is in the unsecured/dev
mode where any authenticated user is a manager - run
`lazysite-users.pl setup-manager` (or grant `ui` to a group) to secure it, as
before.

## WebDAV publishing (SM070)

A WebDAV endpoint (`/dav`) is available for headless, per-file
content publishing. It is **off by default** — an existing install is
unchanged after upgrade until you opt in. To enable it:

1. Add `webdav_enabled: true` to `lazysite/lazysite.conf`.
2. Add the `/dav` ScriptAlias to your web server. The shipped Hestia
   templates include it; for a hand-rolled Apache vhost add
   `ScriptAlias /dav /path/to/cgi-bin/lazysite-dav.pl` and ensure the
   `RequestHeader unset X-Remote-*` lines are present (now in the
   shipped templates).
3. For each publishing account, set `webdav on` (and usually a
   `dav_scope`) on the manager Users page, then generate a credential.

The Hestia templates also gained the `RequestHeader unset X-Remote-*`
directives that `docs/architecture/security.md` has always required;
they need Apache's `mod_headers`. See
`docs/features/configuration/webdav.md` for the full guide.

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
