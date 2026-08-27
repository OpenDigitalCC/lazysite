---
title: "SM215 - sudo-safe helpers + updater that never break perms, and a repair tool"
subtitle: "Field sites drift into a state where files under lazysite/ are owned by a third user (root, from a sudo tool run) that the www-data CGI cannot access - auth/users/groups, .install-state.json, .consume.lock, audit.log. The setgid dirs preserve the GROUP but nothing sets the OWNER when a helper runs as root, so a credential reset or an install under sudo poisons ownership. Make every write owner-safe under sudo, make the updater preserve perms, and ship a repair tool for when drift has already happened."
brand: plain
status: shipped
status-note: "SHIPPED (0.9.17, alongside SM213 stats). Implemented: (1) Lazysite::Util::secure_write_perms - a just-written file inherits owner+group from its provisioned parent dir, and when run as root (sudo) chowns the USER owner too (never leaves a root-owned file); applied in the Auth::Settings + users-tool credential/settings/groups writers, and install.pl's config-replace path now preserves the file's owner as root. (2) tools/lazysite-fix-perms.pl - dry-run-by-default repair tool that re-asserts owner:group + the runtime_paths modes (auth 2770/0660, forms 2775, cache/logs/stats 2775 setgid, per-form conf 0640) across lazysite/; classified as a shipped tool. Tests t/tools/30-fix-perms.t. NB the flagged smtp.conf 0644 is unconfigured (no secret at risk) - the tool sets 0640 as hygiene. PROPOSED 2026-07-27, planned for 0.9.17 (alongside SM213 stats). Origin: the 0.9.16 deploy health summary - stable sites (marriage-morris, outsourcify) flagged lazysite/ paths owned by neither the site user nor www-data, and forms not group-writable. Root cause located: the 02770 setgid auth-dir + 0660 writes preserve the GROUP (www-data) but no helper sets the USER owner, so anything run as root/sudo (a password reset, an install) leaves root-owned files the CGI cannot write. Three parts: (1) sudo-safe writes in the helpers, (2) the updater/overlay preserves owner+mode, (3) a lazysite-fix-perms repair tool. NB smtp.conf world-readable is NOT a live secret (unconfigured on the flagged site) - a hygiene mode, not an exposure."
---

# SM215 - sudo-safe helpers, a perms-safe updater, and a repair tool

## Why

The 0.9.16 deploy health summary flagged, on stable sites, paths under
`lazysite/` "owned by neither the site user nor www-data - a foreign owner the CGI
cannot access": `auth/users`, `auth/groups` (marriage-morris);
`.install-state.json`, `auth/.consume.lock`, `logs/audit.log` and a non-group-
writable `forms/` (outsourcify). A foreign owner on the credential store breaks
login; on the lock and log it breaks CGI writes.

Root cause (located in source): the model relies on **setgid dirs + group-write**.
`lazysite/auth` is `02770` (setgid) and the writers `chmod 0660`
(`Auth/Settings.pm` write_users/write_settings; `lazysite-users.pl` credential +
groups writers; `install.pl` seed writers). setgid makes a NEW file inherit the
directory's GROUP (www-data), and `0660` keeps it group-writable - so far so good.
But **nothing sets the USER owner**. When a helper runs as **root** (an operator
doing a credential reset or an install under `sudo`), the new/rewritten file is
owned by `root` - group www-data, mode 0660, so the CGI can often still *read* it,
but the file now fails the "owner is the site user or www-data" invariant, and any
path that isn't group-writable (a mode that drifted, or a file created outside the
setgid dir then moved in) the CGI cannot *write*. `install.pl` already does
`chown -1, $orig_group, $tmp` (group only) - it never asserts the user owner.

So the drift is not the site agent (it writes via the control API / WebDAV, which
run as www-data) and not a conflict between installers - it is that **our own
helpers and updater are not owner-safe when invoked as root**, and there is **no
tool to repair** a site once drift has happened.

## Design

Three parts. The unifying rule: a privileged write must leave the file owned by
the **site user**, group **www-data**, with the path's declared mode - regardless
of who invoked it.

### 1. Sudo-safe writes in the helpers

A shared helper (extend the existing temp-then-rename writers rather than add a
parallel path):

- `_own_and_mode($path, $tmp)` - before the rename, set group www-data + the
  declared mode (as today), and, **when running as root (`$> == 0`)**, `chown`
  the USER owner to the site owner. The site owner is resolved once per run as:
  the owner of the existing target (preserve it), else the owner of the docroot /
  the `lazysite/` tree, else a configured `site_user`. Never leave a root-owned
  file. When not root, behave exactly as today (group + mode only; a `chown` to a
  different user would fail for a non-root CLI and is not attempted).
- Apply it in every credential/settings/groups writer (`Auth/Settings.pm`,
  `lazysite-users.pl`) and the seed/settings writers in `install.pl`, so a
  `sudo lazysite-users … reset` or a `sudo install` can no longer poison
  `auth/users`.
- The `.consume.lock` and `audit.log` writers (CGI-owned in normal operation) get
  the same treatment so a one-off privileged run does not leave them root-owned.

### 2. The updater preserves owner + mode

The overlay updater (`install.pl` overlay / the deploy path) must, for every file
it creates or replaces, route through the same `_own_and_mode` helper - preserving
an existing file's owner+mode and, for a new file created as root, setting the site
owner. Today it preserves the group and mode of an *existing* file but can create a
*new* root-owned file. This closes the "an upgrade under sudo re-introduces the
drift" path, so that once a site is clean a rollout keeps it clean.

> Wiring note (as built): `lazysite-check --fix` was already the canonical,
> tested repairer (it applies chmod always + chown as root via a handover mode
> that preserves the CGI's access, then re-runs every check). So the standalone
> `lazysite-fix-perms` is a thin front-end that delegates to `lazysite-check`
> (dry-run) / `lazysite-check --fix` (`--apply`) - one implementation, not two -
> and `lazysite-check`'s runtime-dir map gained `lazysite/stats` (the SM213 store)
> so the repair also covers it. This is the "wire --fix to the repair tool"
> increment.

### 3. A repair tool for drift that already happened

`lazysite-fix-perms <docroot>` (a standalone tool, and wired as
`lazysite-site fix-perms` / an optional `lazysite-check --fix`): walk `lazysite/`
and re-assert the spec from `dist/config/classification.json` `runtime_paths` -
owner = site user, group = www-data, and the declared modes (auth `2770`/`0660`,
forms `2775`, cache/logs/stats `2775`, per-form secret confs `0640`). Idempotent,
must run as root (it is a chown), dry-run by default with a `--apply`, and it
prints exactly what it changed. This is the immediate remediation for the flagged
sites and the operator's "repair if something goes awry" ask.

`lazysite-check` already DETECTS this class (it produced the health report); the
repair tool is its remediation counterpart, and `--fix` lets detection and repair
be one step.

## Scope notes

- **Not a live secret.** The flagged `smtp.conf 0644` is unconfigured on that site
  (no credentials), so it is a mode-hygiene item (the repair tool sets it `0640`),
  not an exposure.
- **No behaviour change when run unprivileged.** A non-root CLI keeps today's
  group+mode behaviour; the owner `chown` is root-only (it is the only context that
  can, and the only context that causes the drift).
- **Provisioning stays where it is.** SM215 does not move provisioning into the
  packaging; it makes the existing helpers + updater owner-safe and adds repair.

## What ships in 0.9.17 (with SM213)

Parts 1-3: the `_own_and_mode` sudo-safe writer applied across the credential /
settings / groups / seed writers and the overlay updater, and the
`lazysite-fix-perms` repair tool (+ `lazysite-check --fix`). Planned into 0.9.17
alongside the SM213 stats work so a single beta covers both.

## Tests

- Unit: `_own_and_mode` as root (mocked `$>`/chown) sets owner=site-user,
  group=www-data, the declared mode; as non-root, group+mode only, no chown
  attempt; preserves an existing target's owner.
- A write run "as root" against a temp tree leaves `auth/users` owned by the
  site user (not root), group www-data, `0660`.
- `lazysite-fix-perms --apply` on a tree with a root-owned `auth/users`, a
  `2755` forms dir and a `0644` secret conf restores owner + `2775` + `0640`;
  dry-run changes nothing and reports the diff; idempotent on a second run.
- `lazysite-check` still flags the drift before repair and is clean after.

## Rollout

Beta-channel first (0.9.17). Operators run `lazysite-fix-perms --apply` (or
`lazysite-check --fix`) once on the currently-drifted stable sites; from then the
sudo-safe helpers + updater keep them clean. NB the stable sites' OTHER warnings
(missing protected system-page defaults) are a separate class fixed by promoting
stable to >= 0.9.13 (SM201), not by SM215.

Related: `lib/Lazysite/Auth/Settings.pm`, `tools/lazysite-users.pl`, `install.pl`,
`tools/lazysite-site.pl`, `tools/lazysite-check.pl`, `dist/config/classification.json`
(`runtime_paths` is the spec the repair tool asserts), SM139 packaging, and the
0.9.16 deploy health summary.
