---
title: Update channel (stable vs edge)
---

A site can choose **which lazysite upgrades it accepts**, so a not-yet-certified
release can be kept off stable customer sites while test sites take everything.

This is *not* a self-updater. Upgrades still happen the normal way - an operator
deploys a release tarball and runs the installer. The channel is a **site
preference** that the installer enforces: a `stable` site refuses an `edge`
upgrade.

## The two channels

A release is built as one of:

- **stable** - certified; cut with `release.sh --final` (stamps
  `channel: stable` into the release manifest).
- **edge** - everything else (the default for every build).

A site is set to one of:

- **all** (default) - installs every release, exactly as before.
- **stable** - installs only `stable` releases. An `edge` upgrade is **skipped**:
  no files change, the installer exits 3 (a clean no-op, not an error), and the
  skip is recorded in the site's audit trail as `upgrade-skipped`.

The site preference is `update_channel` in `lazysite.conf`, set from
**Manager → Site settings → Update channel**. Use `stable` for customer sites you
don't want on the cutting edge.

## How it behaves

| Site channel | Release channel | Result                                  |
| ------------ | --------------- | --------------------------------------- |
| all          | edge or stable  | installs (today's behaviour)            |
| stable       | stable          | installs                                |
| stable       | edge            | **skipped** + audited; nothing changes  |

Only *upgrades* are gated. A fresh install or a reinstall of the same version is
the operator's explicit choice and is never skipped.

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
