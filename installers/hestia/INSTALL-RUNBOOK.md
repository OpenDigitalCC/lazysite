# lazysite on HestiaCP — install runbook (DRAFT)

Status: draft, captured live during the community.dhcf.eu install
(2026-06-21). To be refined into house style and committed alongside the
`lazysite-app` template. Covers a second Hestia web template that does
NOT disturb existing lazysite/ssi sites on the same box.

## Model: two layers

- Hestia **web template** (`.tpl`/`.stpl` + `.sh` rebuild hook) owns the
  Apache vhost (FallbackResource, ScriptAlias /dav, the `/lazysite/`
  deny, header strips) and, via the root-run hook, the directory layout
  and permissions. Routing survives every rebuild (SSL renew, alias
  change).
- `install.pl` owns the **code/seed deploy and upgrades** (manifest +
  state + backups). Re-run it to upgrade; rebuilds never touch code.

A *second* template (`lazysite-app`) is added; the existing `ssi-md`
template and the sites on it are left untouched. Upgrades to one site =
re-run install.pl against that site only.

## CRITICAL: FallbackResource must point at lazysite-auth.pl

For built-in cookie auth (login + the manager UI) to work, the Apache
`FallbackResource` must be `/cgi-bin/lazysite-auth.pl`, NOT
`/cgi-bin/lazysite-processor.pl`. `auth.pl` validates the signed cookie,
sets `X-Remote-User`/`X-Remote-Groups`, then `exec`s the processor; with
FallbackResource pointing straight at the processor the cookie is never
read, so every page is unauthenticated and `/manager/` redirects to
`/login` in a loop even after a correct login. `auth.pl` execs the
processor unconditionally, so it is a safe default (public pages still
render with no cookie). The repo `lazysite.tpl`/`.stpl` ship the no-auth
wiring; the `lazysite-app` template must use `auth.pl`.

BUT FallbackResource only covers NON-EXISTENT paths (pages like
`/manager/`). The manager UI's AJAX calls hit `/cgi-bin/lazysite-manager-api.pl`,
a REAL file served straight by `ScriptAlias /cgi-bin/`, so it bypasses
`auth.pl`, gets no `X-Remote-User`, and (with `manager_groups` set)
rejects every call -> the manager renders but every panel is stuck on
"Loading...". `security.md` states the contract: "every `/cgi-bin/*.pl`
request (except those targeting `lazysite-auth.pl` itself) passes through
the auth wrapper". The dev server implements it by running `auth.pl` with
`LAZYSITE_PROCESSOR=<target>`; the Hestia template must replicate it with
mod_rewrite:

```apache
RewriteEngine On
# Front cgi-bin scripts with the auth wrapper so the session cookie
# becomes X-Remote-User before the target runs. auth.pl execs
# LAZYSITE_PROCESSOR. Excludes auth.pl (recursion); /dav has its own
# ScriptAlias and does its own Basic auth.
RewriteRule ^/cgi-bin/(lazysite-(?:processor|manager-api)\.pl)$ \
    /cgi-bin/lazysite-auth.pl \
    [E=LAZYSITE_PROCESSOR:%{DOCUMENT_ROOT}/../cgi-bin/$1,PT]
```

Needs `a2enmod rewrite`. `auth.pl` now also reads
`REDIRECT_LAZYSITE_PROCESSOR` in case Apache prefixes the [E=] var after
the passthrough. This rule belongs in BOTH `lazysite-app.tpl` and
`.stpl`.

## Critical environment facts (this box)

- Two shell users: `sysadmin` (has sudo) and `ispadmin` (domain owner,
  NO sudo). Run install.pl and the users tool as `ispadmin`; privileged
  steps as `sysadmin`.
- `WEB_SYSTEM=apache2`, backend `php-fpm`, proxy `nginx`.
- Hestia scans web templates at
  `$WEBTPL/$WEB_SYSTEM/$WEB_BACKEND/` — i.e.
  `/usr/local/hestia/data/templates/web/apache2/php-fpm/`, NOT
  `.../apache2/`. A template placed one level too high does not appear
  in `v-list-web-templates` or the dropdown.
- The Hestia domain root dir (`web/<domain>/`) is mode `0551` — the
  owner cannot create files in it. `install.pl` needs to create
  `plugins/` and `tools/` as siblings of `public_html`, so those must be
  created as root (the template hook does this) or via a manual
  `sudo chmod u+w` window.
- `SuexecUserGroup` is commented out in the template, so Apache CGI runs
  as **www-data** (not the domain user). Everything the web app writes
  (`.secret`, `.login-rate.db`, rendered `.html`, cache/logs) is written
  as www-data.
- `nginx.conf` already sets `client_max_body_size 1024m;` globally — do
  NOT add another in conf.d (duplicate directive = nginx won't start).

## One-command deploy (recommended)

Once the `lazysite-app` template is on the host (the three files under
`…/web/apache2/php-fpm/`, plus `a2enmod headers rewrite`), a whole domain
install/upgrade is ONE command, run as root from an unpacked release:

```
sudo bash STAGE/installers/hestia/lazysite-hestia-deploy.sh USER DOMAIN STAGE
# e.g. sudo bash /tmp/lazysite-0.3.6/installers/hestia/lazysite-hestia-deploy.sh \
#        ispadmin community.dhcf.eu /tmp/lazysite-0.3.6
```

It applies the template, runs `install.pl` as the domain user, sets the
www-data docroot perms (`2775` dirs / `664` files, `2770` on auth/forms),
and drops the Hestia `index.html` stub. On a NEW install it prints the two
remaining first-run touches (`manager_groups`/`webdav_enabled` in
`lazysite.conf`, and the manager password).

This is the fix for "`install.pl` as the domain user can't write the
0551-locked domain root or chgrp to www-data": **run the whole thing as
root, once.** The manual steps below are the breakdown of what the wrapper
does (and the fallback if you're not using it).

## Procedure

1. Create the template (as `sysadmin`) in the **php-fpm backend** dir.
   Use the `lazysite-app` files (cookie auth wrapper + manager + WebDAV); the
   plain `lazysite.tpl`/`.stpl` are the basic, no-auth variant:
   - `cp installers/hestia/lazysite-app.tpl  .../apache2/php-fpm/lazysite-app.tpl`
   - `cp installers/hestia/lazysite-app.stpl .../apache2/php-fpm/lazysite-app.stpl`
   - install the thin hook as `.../apache2/php-fpm/lazysite-app.sh`
     (creates plugins/tools in the locked domain root, sets
     `<owner>:www-data` + setgid `2775` across the docroot, `2770` on
     `lazysite/auth`; does NOT deploy code), `chmod 755`.
2. `a2enmod headers rewrite` (the `RequestHeader unset` lines need
   mod_headers, else `configtest` fails with `Invalid command
   'RequestHeader'`; the cgi-bin auth rewrite needs mod_rewrite). For
   overlaying an SSI (`.shtml`) static site, also `a2enmod include` so the
   template's `AddOutputFilter INCLUDES`/`Options +Includes` take effect;
   without it `.shtml` is served as raw HTML. Restart apache2 afterwards.
3. Apply: `v-change-web-domain-tpl <user> <domain> lazysite-app yes`.
   The root hook runs and fixes the locked-dir + perms.
4. Install (as `ispadmin`, absolute paths — do not rely on shell vars
   across a `su -` boundary): `bash install.sh --docroot <docroot>
   --cgibin <cgibin> --domain <domain>`.
5. Post-install fixups:
   - Delete the Hestia default `index.html` (and any static
     `robots.txt`) from the docroot — nginx serves `.html` statically,
     so Hestia's stub shadows lazysite's `index.md` and the site shows
     the Hestia placeholder. lazysite regenerates `index.html` from
     `index.md` on the next request.
   - Enable WebDAV at the SITE level: add `webdav_enabled: yes` to
     `lazysite/lazysite.conf`. This is separate from the per-user
     `set <user> webdav on`; BOTH gates must be on, and the site gate
     defaults OFF (so `/dav` returns 404 — by design — until set).
   - Set the manager password (see below).
   - Verify `auth/` is writable by the CGI user (www-data) so `.secret`
     can be minted — otherwise login 500s with
     `End of script output before headers: lazysite-auth.pl`.

## Updating every site at once

To upgrade all lazysite sites on the host from one release, instead of running
the per-site deploy by hand:

```bash
tar xzf lazysite-X.Y.Z.tar.gz -C /tmp
# preview which sites are found and their current versions
sudo bash /tmp/lazysite-X.Y.Z/installers/hestia/lazysite-hestia-update-all.sh --list
# update them all (code + content + perms)
sudo bash /tmp/lazysite-X.Y.Z/installers/hestia/lazysite-hestia-update-all.sh
```

It discovers sites by their own marker (`public_html/lazysite/.install-state.json`),
so it never touches non-lazysite domains, and runs the normal per-site deploy
for each (a per-site failure is reported and the run continues). Add
`--templates` to also refresh the shared `lazysite-app` web template first - do
that for a release that changes the vhost (e.g. a new `FilesMatch`), once you
have confirmed your sites use the `lazysite-app` template.

## The seeded `manager` account (first-login gotcha)

The install seeds `lazysite/auth/users` from `users.example`, which
ships ONE line: `manager:` — user `manager` with an EMPTY password
(it is in the `lazysite-admins` and `members` groups via
`groups.example`). There is no default password to "know".

- `passwd manager '<pass>'` sets the password in place. (It used to fail
  "User not found" because `passwd` tested the truthiness of the empty
  hash; now fixed to test existence. `add manager '<pass>'` also works.)
- An empty-password account can only sign in from localhost
  (127.0.0.1/::1); a remote browser login is refused. So the correct
  first-run step is: operator sets the manager password with the users
  tool. (Logging in "without a password" is only possible on the server
  itself.)
- Interactive login requires `ui` on. Also set the SM071 capabilities
  if this account manages themes/layouts/config:
  `set manager ui on`, `set manager manage_themes on`,
  `set manager manage_layouts on`, `set manager manage_config on`,
  `set manager webdav on`.

## Permissions model (suexec off → CGI = www-data)

- docroot: `<owner>:www-data`, dirs `2775` (setgid + group-write) so
  www-data can write generated `.html` anywhere and new dirs inherit the
  group.
- `lazysite/auth`: `2770` `<owner>:www-data` so www-data can mint
  `.secret`, write `.login-rate.db`, and (for web-based user management)
  rewrite `users`/settings. A stale `.secret` owned by the wrong user
  (left over from perms churn) must be removed so it re-mints.
- The template hook re-asserts all of this on every rebuild.

## The `--domain` minimal-conf trap (manager 403)

`install.pl --domain NAME` writes a MINIMAL `lazysite.conf` containing
only `site_name` and `site_url`. The full `starter/lazysite.conf.example`
ships `manager: enabled` + `manager_path: /manager`; the minimal conf
omits them, so `manager` defaults to `disabled` and `/manager/` returns a
bare `403 Forbidden` (via `handle_manager_path` -> `forbidden()`).

Two more "default off" site gates live in the same conf:

- `manager: enabled` — without it the manager UI is a hard 403.
- `manager_groups: <group>` — if UNSET, ANY authenticated user is
  treated as a manager (`_is_manager` returns 1). Set it to
  `lazysite-admins` so only that group has manager access.
- `webdav_enabled: yes` — site gate for `/dav` (separate from per-user
  `set <user> webdav on`); defaults off (so `/dav` is 404 until set).

Fix on a live site: append to `lazysite/lazysite.conf`:

```
manager: enabled
manager_path: /manager
manager_groups: lazysite-admins
webdav_enabled: yes
```

Better: do NOT use `--domain` for a real install — seed the full
`lazysite.conf.example` and edit `site_name`/`site_url`, so the manager
and the documented layout/theme/plugins keys are all present.

## First credentials / password model

There is NO self-service password reset or email flow in the built-in
auth. First credentials are always provisioned by the account's creator:

- The seeded `manager` ships with an EMPTY password (localhost-only
  until set). Operator sets it: `add manager '<pass>'`.
- New human accounts: `account-create <user> <pass> --by <parent>` — the
  parent sets the initial password and shares it out-of-band; the
  manager UI (`/manager/users`) can also add users and has a per-user
  "Password" (change) button.
- Machine/strong credential: `token <user>` (shown once).
- AI/automation partners: `partner-create` issues a single-use,
  short-lived PAIRING KEY (printed in the onboarding brief) which the
  partner exchanges for a rotating access token — no human password.

So a new user "gets their first password" from whoever created the
account; there is no public registration or forgot-password page.

## Starter content polish (flagged live)

- `starter/404.md` previously said the same thing four times (title +
  subtitle + `## Nothing here` + body). Tightened to one message + a
  next action.
- `/docs/features/` (trailing slash) 404s: the overview ships as
  `docs/features.md` (served at `/docs/features`), and the category dirs
  (`authoring`, `configuration`, `development`) have no `index.md`, so a
  directory request finds nothing. Either add `index.md` landing pages,
  or (better) have the processor serve a sibling `<dir>.md` when a
  directory is requested and `<dir>/index.md` is absent.

## Validated end-to-end (2026-06-22, community.dhcf.eu)

A clean clear-down + reinstall from patched 0.3.2 + the `lazysite-app`
template proved the corrected flow with NO per-request whack-a-mole:
site renders, login issues a cookie with the right groups, the manager
renders with chrome (mg-nav, 19.5 KB), the manager-api authenticates
(csrf ok), the site-config plugin is discovered, and WebDAV is 207.

Test-harness gotcha: `curl -c JAR` silently does NOT persist the
`Secure` `lazysite_auth` cookie, so every cookie-based curl check reads
as unauthenticated. Send it explicitly (`-H "Cookie: lazysite_auth=..."`)
or just test in a browser. This wasted hours - don't trust an empty curl
cookie jar as evidence the session is broken.

The four code bugs this surfaced (all now fixed in the tree):

1. `lazysite-processor.pl get_layout_path` keyed only on `REDIRECT_URL`;
   behind the auth wrapper that's empty, so the manager layout was never
   selected -> chrome-less manager. Now falls back to `REQUEST_URI`.
2. `lazysite-manager-api.pl action_plugin_list` looked for core scripts
   at `$DOCROOT/..`; a real install has them in `cgi-bin/`. Now falls
   back to `$base/cgi-bin/$rel` -> site-config plugin discovered.
3. `lazysite-auth.pl` exec target now also reads
   `REDIRECT_LAZYSITE_PROCESSOR` (Apache prefixes the rewrite [E=] var).
4. `lazysite-users.pl` re-`chmod 0750`'d the auth dir on EVERY run,
   reverting the operator's `2770` and breaking `.secret` minting (login
   500) after any add/passwd/set. Now only chmods on creation.

Deploy-wrapper ordering rule (for the deb): run ALL user-tool ops first,
then set perms last - or, with fix #4 in place, the order no longer
matters. Files the tool writes (`users`, `groups`, `user-settings.json`)
come out group `ispadmin` / mode 0640, so the wrapper must `chgrp
www-data` + `chmod 660` them after seeding the admin account.

## WebDAV performance (davfs2 and friends)

WebDAV runs as CGI and clients like davfs2 re-send Basic auth on EVERY
request. Per-request latency is dominated by:

- Auth. A password is a 100,000-iteration KDF - ~117 ms measured PER
  REQUEST. A token credential (prefix `lzs_`) verifies in one iteration
  (~0 ms). So MOUNT WITH A TOKEN, not the password: mint one with
  `lazysite-users.pl --docroot DOCROOT token USER` (or the Users page
  "Generate credential") and use it as the password. Biggest single win.
- CGI process spawn (~30 ms/request). Removing it needs a persistent
  worker (FastCGI/PSGI) - deliberately deferred; not worth it once auth
  is cheap and the client is tuned.

Reduce davfs2 chattiness in `/etc/davfs2/davfs2.conf` (or `~/.davfs2/`):

```
use_locks    0     # skip LOCK/UNLOCK round-trips - biggest client lever
gui_optimize 1
dir_refresh  30
file_refresh 30
cache_size   256   # MiB
delay_upload 2
```

The `lzs:sha256` PROPFIND property (content-drift detection, scoped to the
`lazysite/layouts/` subtree) is computed only when a client requests it by
name, so vanilla clients never pay the hashing cost.

## Suggested code improvements (for the commit)

- `install.pl` `--domain`: seed from `lazysite.conf.example` (substitute
  `site_name`/`site_url`) instead of writing a bare two-key conf, so the
  manager and other gates aren't silently disabled.
- `install.pl` fresh-install: if a docroot `index.html` matches Hestia's
  default stub (content hash), delete it (content-matched so real HTML
  is never touched). Saves the manual delete in step 5.
- `lazysite-app.sh` hook: CREATE `lazysite/auth` at `2770` itself, so the
  `auth`-writable fix is not order-dependent (currently the hook's
  `chmod 2770 auth` is a no-op when applied before `install.pl` creates
  the dir, leaving it `0750` and breaking `.secret` minting -> login
  500). Alternatively the manifest should mark `auth` group-writable on
  www-data-CGI setups.
- `lazysite-users.pl`: `passwd`/`add` empty-hash handling is confusing
  (`passwd` says "not found" for a present-but-passwordless user).
  Consider distinguishing "exists with empty hash" from "absent".
- `handle_manager_path`: a disabled manager returns a bare unstyled
  `403 Forbidden` (via `forbidden()`), not the styled `403.md` or a
  redirect. Consider 404 (feature off, like webdav) or rendering
  `403.md`.
- Consider shipping the `lazysite-app` Hestia template (php-fpm backend)
  + this runbook in `installers/hestia/`.

## WebDAV route (/dav/) - provisioning and health check (SM121)

The Apache vhost template wires WebDAV with `ScriptAlias /dav` ->
`cgi-bin/lazysite-dav.pl`, and `lazysite-dav.pl` does its own Basic auth and
honours `webdav_enabled` in `lazysite.conf`. So once the apache2 backend is in
place, `/dav/` should answer with **401** even unauthenticated (an auth
challenge), never **404**.

If `/dav/` returns a **404 even unauthenticated**, the web server / nginx proxy
is not forwarding `/dav/` to Apache - a route/provisioning problem, not auth.
This has been seen when the proxy (nginx in front of apache2) serves `/dav/` as
a static path instead of proxying it, or when the domain was created
nginx-only (no apache2 backend - lazysite requires `WEB_SYSTEM=apache2`).

**Health check** (the fast 404-vs-401 diagnostic):

```bash
perl tools/lazysite-check.pl --docroot "$DOC" --check-dav "https://your-domain"
# OK   -> WebDAV /dav/ is routed (401 challenge)
# FAIL -> 404: the proxy/web-server is not forwarding /dav/ (wire it + reload)
```

or by hand:

```bash
curl -sS -k -o /dev/null -w '%{http_code}\n' https://your-domain/dav/   # want 401
```

To fix a 404: confirm the domain uses the apache2 backend (so the
`ScriptAlias /dav` template applies), and that the nginx proxy template
forwards `/dav/` (and `/cgi-bin/`) to Apache rather than serving them as static.
Reload the web server after changes.

## Overlaying lazysite on an existing static site (SSI)

`lazysite-app` is an overlay: existing files are served directly and only
non-existent paths fall through to the markdown processor
(`FallbackResource`). So a static site keeps working **as long as its
homepage and pages are reachable through this vhost**:

- The homepage must be one of `DirectoryIndex index.html index.htm
  index.shtml`. If the original homepage is `index.shtml` it is served (and
  SSI-processed) and lazysite never renders its placeholder over it. If it is
  something else (e.g. a PHP front controller), `/` falls through to lazysite -
  `lazysite-app` has **no PHP handler**, so do not overlay PHP/dynamic sites
  with it (revert such a domain to its original template).
- SSI (`.shtml`) needs `a2enmod include` (see step 2); the template enables
  `Options +Includes` and `AddOutputFilter INCLUDES .shtml`.
- If a domain was overlaid before this fix and lazysite already rendered its
  placeholder to `index.html`, remove that one file so the real `index.shtml`
  wins again: `rm <docroot>/index.html` (and `rm <docroot>/index.md` if the
  lazysite starter homepage is unwanted).

To take a domain back off lazysite entirely, switch its web template back
(`v-change-web-domain-tpl <user> <domain> default` then rebuild); the lazysite
files left in the docroot are inert without the template.
