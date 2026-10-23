---
id: SM1307
title: "SM1307: a security release reaches the stable sites of a Hestia fleet"
subtitle: "Ruling 41b pushes 0.16.2 to every site with upgrade --all --force-security, which reaches only registered sites - and a Hestia host registers none, while its updater scoped by update_channel alone. The updater takes --force-security now, refused unless the release declares security_critical, and upgrade --all on such a host names it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "found building SM1305 for ruling 41b; asked for by the supervisor the same day"
area: installers
status-note: "SHIPPED (0.16.2) on n738: lazysite-hestia-update-all.sh --force-security; install.pl --force-security (the channel override, checked against the manifest); the per-site deploy passes it; lazysite upgrade --all on a Hestia host with no registry names the updater and exits 1. t/tools/291."
---

# What happened

Ruling 41b: 0.16.2 is cut marked `security_critical` and pushed fleet-wide with
`lazysite upgrade --all --force-security`, so that it reaches stable sites too.
Building SM1305 showed that route reaches nothing on a HestiaCP host:

- `upgrade --all` reads only the registry at `/etc/lazysite/sites.d`, which
  `provision` writes and the tarball path never runs. On a Hestia host it
  printed "no sites registered" and exited 0 - a fleet with nothing to do.
- `lazysite-hestia-update-all.sh`, that fleet's path, scopes each site with
  `install.pl --channel-check` (SM345) and never read `security_critical`, so an
  edge build stayed off every stable site whatever the release declared.

# What shipped

- **`lazysite-hestia-update-all.sh --force-security`.** Refused (exit 2) before
  anything else - before the root check, before a site is looked at - unless
  the staged `release-manifest.json` declares `"security_critical": true`. With
  it, a site the channel check puts out of scope is asked again with
  `install.pl --channel-check --force-security`, and is put in scope when that
  answers 0. The scope decision stays the installer's, as SM345 wanted.
- **`install.pl --force-security`**, the narrowest point: `--force` for a payload
  whose manifest declares `security_critical`, refused (exit 2) for any other.
  With `--channel-check`, a site whose channel refuses the build answers 0 and
  says it was forced. The upgrade's audit row is `upgrade-forced`, naming the
  override: `--force-security override (security_critical release)`.
- **The per-site deploy** (`lazysite-hestia-deploy.sh`) passes
  `--force-security` to both its channel pre-check and the install when the
  updater exports `LAZYSITE_FORCE_SECURITY=1`, and stops untouched if
  install.pl refuses it.
- **Reporting.** The table shows a forced site as `in scope (forced: security
  release)` and lists the forced sites under it; each gets a findings line (its
  channel, the build, the declaration); the lists after the repair print
  `FORCED IN (...)`.
- **Excluded sites stay excluded.** Exclusion (an install marker without the
  lazysite-app template) is decided at discovery, before scope, and the
  override touches only the channel decision.
- **Policy.** The updater reads no `update_policy`, so there is none to
  override; the CLI's `--force-security` still overrides it for registry hosts.
- **`lazysite upgrade --all` on a Hestia host with no registry** fails (exit 1)
  naming the updater command, with `--force-security` when it was given. No
  Hestia fallback is built into the CLI: the updater is that fleet's path.
- Docs: OPERATOR.md "Security releases", UPGRADE.md, the updater's usage and
  install.pl's usage and POD.

# Tests

- t/tools/291. install.pl: a stable site refuses an edge build without the flag
  (exit 3); with it, a security-critical build is forced (exit 0, saying so); the
  same flag against a payload without the declaration is refused (exit 2). The
  updater refuses `--force-security` for such a payload before its root check.
  The updater's discovery and scope blocks as they ship, over a stand-in lister
  and the real install.pl: without the flag scope is unchanged, held against the
  same fleet with the flag where the stable site moves in; with it the stable
  site is in scope, named in the table and the findings, and the excluded site
  stays excluded; a payload without the declaration forces nothing, against one
  with it that does. The deploy passes the flag to both install.pl calls. And
  `upgrade --all` with an empty registry on a Hestia host names the updater and
  exits 1.
- With install.pl, both Hestia scripts and lazysite-cli.pl as on main, every
  subtest fails except the one that finds the blocks.
