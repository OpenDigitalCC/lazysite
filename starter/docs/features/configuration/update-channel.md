---
title: Update channel (the edge < beta < stable ladder)
---

A site can choose **which lazysite upgrades it accepts**, so a not-yet-certified
release can be kept off stable customer sites while test sites take everything.

This is *not* a self-updater. Upgrades still happen the normal way - an operator
deploys a release tarball and runs the installer. The channel is a **site
preference** that the installer enforces: the site's channel is the *minimum
release maturity* it accepts.

## The channel ladder

A release is built as one of three maturities, `edge < beta < stable`:

- **edge** - every release (the default for every build); early testing.
- **beta** - a tested, bedding-in candidate; cut with `release.sh --beta`.
- **stable** - certified for customer rollout; cut with `release.sh --final`
  (each stamps its `channel` into the release manifest).

A site is set to one of:

- **all** (default) - installs every release, exactly as before.
- **beta** - installs `beta` and `stable` releases; `edge` upgrades are skipped.
- **stable** - installs only `stable` releases.

A skipped out-of-channel upgrade changes no files: the installer exits 3 (a
clean no-op, not an error) and the skip is recorded in the site's audit trail
as `upgrade-skipped`, naming both channels.

The site preference is `update_channel` in `lazysite.conf`, set from
**Manager → Site settings → Update channel**. Use `stable` for customer sites you
don't want on the cutting edge, and `beta` for sites that should track tested
builds without waiting for certification.

## How it behaves

| Site channel | Release channel      | Result                                  |
| ------------ | -------------------- | --------------------------------------- |
| all          | edge, beta or stable | installs (today's behaviour)            |
| beta         | beta or stable       | installs                                |
| beta         | edge                 | **skipped** + audited; nothing changes  |
| stable       | stable               | installs                                |
| stable       | edge or beta         | **skipped** + audited; nothing changes  |

Only *upgrades* are gated. A fresh install or a reinstall of the same version is
the operator's explicit choice and is never skipped.

## Fleet upgrades: `update_policy`

On hosts managed with the `lazysite` CLI, a second conf key,
`update_policy: auto|manual` (default `manual`), decides whether the fleet-wide
`lazysite upgrade --all` run touches this site at all. `auto` sites are
upgraded when the channel above accepts the payload; `manual` sites are skipped
and upgraded only when the operator chooses. A release whose manifest declares
`"security_critical": true` can be pushed through both gates with
`lazysite upgrade --all --force-security`. Set the key with
`install.pl --policy auto|manual --docroot <docroot>` (audited as `policy-set`).

## Cutting a stable release (operator)

    tools/release.sh --final X.Y.Z          # channel: stable
    tools/release.sh X.Y.Z                  # channel: edge (default)

The Hestia deploy wrapper understands the skip: if the installer reports a
channel skip it prints a notice and exits cleanly (it does not run the post-deploy
verify, since nothing changed).

## Recommended workflow

1. Cut every build as `edge` and deploy it to your own test / cutting-edge sites.
2. Once a version is fully tested, cut it again - or re-tag - as `--final`
   (stable) and deploy to customer sites. Customer sites set to `stable` only
   take that certified build; any edge deploy in between is skipped and logged.
