---
id: SM1427
title: "SM1427: a new Hestia site is one command, the first operator included"
subtitle: "Setting up a site from a tarball on a Hestia host took a provision as the wrong user, a hand-written registry line, a path-only claim link and a runbook step naming a template the tarball host does not have. lazysite-hestia-deploy.sh now finishes the site."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "release manager, a new site on a Hestia host, tarball 0.16.9"
area: install
status-note: "SHIPPED (PENDING): lazysite-hestia-deploy.sh USER DOMAIN [--sysop NAME] [--channel C] applies lazysite-proxy, sets site_url (install.pl --site-url), writes the registry entry, runs setup-sysop as the site user, ends with one summary. Installer group message, repair/probe --docroot, setup-sysop notice fixed. t/tools/621-624."
---

# What happened

The release manager set up a new site on a Hestia host from the 0.16.9 tarball and
reported "this is very fiddly - the install should be simpler, and one step rather than
chained to set first user". What went wrong:

- `lazysite-cli.pl provision` was run as the site user. That user is not in `www-data`,
  so 424 paths had no `www-data` group, 14 checks failed and the site answered 500.
- `setup-sysop` was run as root and did not refuse.
- The registry line was written by hand.
- The claim link came out as a path only, because no absolute `site_url` was set.
- The deb runbook's steps named a `lazysite-cgi` template that a tarball host does not
  have.

# What changed

`installers/hestia/lazysite-hestia-deploy.sh USER DOMAIN [STAGE_DIR] [--sysop NAME]
[--channel C]` keeps its behaviour, and a first-time deploy now also:

- applies the `lazysite-proxy` nginx template after `lazysite-app` when Hestia has it, and
  when it does not says so and names the `cp` and `v-change-web-domain-proxy-tpl` commands;
- sets `site_url: https://DOMAIN` when the conf holds no absolute one, through a new
  `install.pl --site-url URL` (a maintenance op like `--channel` and `--policy`, audited as
  `site-url-set`);
- writes `/etc/lazysite/sites.d/DOMAIN` (docroot, cgibin, owner, channel, `policy=manual`;
  the order `lazysite provision` writes), never over an existing entry;
- with `--channel C`, sets the site's `update_channel` (the registry says `edge` otherwise);
- with `--sysop NAME`, after the health check passes, runs `setup-sysop --user NAME` as the
  site user and prints the claim link as a full `https://DOMAIN/claim?...` URL. A rerun on a
  site that already has accounts does what `setup-sysop` does there and says so. Without
  `--sysop` the SM864 message stays, with the one-line rerun;
- ends with one summary: the site, the manager, the claim link, the registry entry and the
  front-end probe commands.

An upgrade is unchanged. SM864 stands: the deploy still invents no account; the operator
names the first one.

Fixed alongside, each its own commit:

- The installer's group message said to run the install as the site owner or root. The
  owner run is the one that fails, and `provision` refuses root. It now names the root
  `lazysite-hestia-deploy.sh USER DOMAIN` on a Hestia host and
  `lazysite-cli.pl repair --docroot D` anywhere. t/tools/621.
- `lazysite repair --docroot D` and `probe --docroot D` died with "Unknown option: docroot",
  though the usage line lists them: both read their sites through `extract_site_targets`,
  which took `--domain` and `--all` only. They take `--docroot` now (a registered site at that
  docroot as registered, otherwise described from the path); `--docroot` with `--all` or
  `--domain` is refused. t/tools/622 also holds each verb whose usage line lists `--docroot`
  to being run against a missing directory or named as one that is not run, so a verb added
  to the usage text must be put in one list on purpose.
- `setup-sysop` printed "this site has no operator yet" in the run that makes the operator.
  The notice belongs to `add` and `group-add` on their own. t/tools/623.
- `lazysite-users.pl` as root: it already becomes the owner of the docroot tree before any
  write and refuses a root-owned tree (SM619, t/unit/tools/70, including a real run under
  `unshare -r`). That is the behaviour of `upgrade --all`, `probe` and `bundle-apply`, and
  `lazysite users --all` as root (SM625) depends on it, so it is left as it is.

# Tests

t/tools/621 (group message), 622 (repair/probe `--docroot` and the usage-line hold), 623
(setup-sysop notice), 624 (the deploy's arguments through the real script, its first-time
functions against stubbed `v-*` commands and `sudo`, with install.pl and lazysite-users.pl
run for real). Each fails on the parent commit.
