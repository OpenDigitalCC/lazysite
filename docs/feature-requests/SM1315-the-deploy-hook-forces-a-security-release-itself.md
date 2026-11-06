---
id: SM1315
title: "SM1315: the deploy hook passes --force-security itself"
subtitle: "0.16.2 declared itself security-critical and the deploy hook ran the Hestia updater with its usual flags, so the stable sites were pushed by hand. Ruling 45: the hook passes --force-security when the stage manifest declares security_critical."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "release manager, ruling 45 (after the 0.16.2 rollout)"
area: tools
status-note: "SHIPPED (0.16.3) on n740: tools/lazysite-deploy.sh reads release-manifest.json from the tarball it deploys and adds --force-security when security_critical is true. t/tools/292."
---

# What happened

0.16.2's manifest declares `"security_critical": true` (SM1305), and the Hestia
updater takes `--force-security` for such a release (SM1307). The deploy hook,
`tools/lazysite-deploy.sh`, ran the updater with its own flags
(`LAZYSITE_DEPLOY_FLAGS`, plus `--reapply-acls`) and never read the
declaration, so the updater scoped the release by each site's `update_channel`
and the operator pushed it to the rest by hand.

Ruling 45: the deploy hook passes `--force-security` itself when the stage
manifest declares `security_critical`.

# What shipped

- **`updater_flags` adds `--force-security`** when the release declares it. The
  declaration is read by a new `security_critical` function from
  `lazysite-X.Y.Z/release-manifest.json` inside the tarball being deployed - the
  tarball the host unpacks into the stage the updater runs from, so it is the
  manifest the updater's own check reads. The test is the updater's: the key's
  truth as JSON::PP decodes it.
- **Absent, false or unreadable adds nothing.** A manifest without the key or
  with `false` deploys as before. A tarball without a manifest, or a manifest
  that is not a JSON object, deploys without the flag and the hook prints a line
  saying it could not read the declaration.
- **The operator's flag is not doubled.** `LAZYSITE_DEPLOY_FLAGS` that already
  carry `--force-security` get it once.
- **Versions are unchanged.** `--force-security` widens which sites the updater
  takes in (install.pl `--channel-check --force-security`); neither the updater
  nor `lazysite upgrade --all --force-security` changes which version is
  installed. The watcher still deploys only a version strictly higher than its
  baseline.
- No version gate: a manifest carries the key only from 0.16.2, whose updater
  takes the flag.
- Docs: OPERATOR.md "Security releases".

# Tests

- t/tools/292 sources the real hook with only `scp` and `ssh` stubbed, over real
  tarballs laid out as release.sh packs them, and records the updater command.
  `security_critical: true` adds `--force-security` (and the deploy line shows
  it); absent and `false` add nothing and warn of nothing; no manifest and a
  manifest that is not JSON add nothing and say so; an operator's own
  `--force-security` appears once; the watch loop does not deploy a
  security-critical version at its baseline and, as the control, deploys it
  with the flag from the version below.
- With the hook as on main, the true, unreadable and control subtests fail.
