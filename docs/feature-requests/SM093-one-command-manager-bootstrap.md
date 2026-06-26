---
title: "SM093 - one-command manager bootstrap"
subtitle: "Getting started must be a single built-in command, not a sequence of fiddly steps"
brand: plain
---

::: widebox
Making the manager usable on a fresh install required four error-prone steps
(`passwd manager`, add `manager: enabled`, add `manager_groups`, `group-add`),
each with path/permission traps - and they're hard to run when you can't paste a
multi-line block. This adds `setup-manager`: one idempotent command that does all
of it, folded into the Hestia deploy so a new site is manager-ready from the single
deploy command.
:::

## Motivation

Field experience: after a fresh deploy, an operator still had to set the manager
password, enable the manager, name an admin group, and put the manager user in it -
four commands, each with a way to get the docroot/user/permissions wrong. One real
failure was a `root`-owned `lazysite/` tree (from running `install.pl` directly as
root rather than via the deploy wrapper) producing "Permission denied" on the
`passwd` step. Getting started should be a single built-in command.

## What ships

`tools/lazysite-users.pl setup-manager [PASSWORD] [--user NAME] [--group NAME]`:

- creates the manager account if absent, else sets its password;
- generates and prints a strong password when none is given;
- creates the admin group and adds the manager user to it;
- ensures `manager: enabled` and `manager_groups: <group>` in `lazysite.conf`
  (idempotent - never duplicates or overrides an operator's existing value; honours
  an existing `manager_groups` by joining its first group);
- prints a "Manager ready" summary with the URL, username, password, and group.

`installers/hestia/lazysite-hestia-deploy.sh` calls it on a fresh install (detected
by the absence of `manager_groups` in the conf), running as the domain user after
the deploy's chown, so the auth store and conf are written with the right
ownership. The single deploy command now fully bootstraps the manager.

## Companion: lazysite-check (install/permissions doctor)

`tools/lazysite-check.pl --docroot DOC [--fix]` is the verification counterpart:
it confirms the install is in the state this bootstrap assumes - the `lazysite/`
tree is owned by the domain user (not root), the CGI-writable dirs are
group-writable + setgid, secrets are not world-accessible, the cgi-bin scripts and
config are present, and the manager is bootstrapped - reporting OK/WARN/FAIL with a
fix hint, and repairing the chmod/chown issues with `--fix`. The Hestia deploy runs
it as a final step, so the root-owned-tree trap that motivated this work is now
caught (and fixable) at deploy time.

## Notes / follow-ons

- The underlying "tree owned by root" trap is avoided by using the deploy wrapper
  (which chowns to the domain user); running `install.pl` directly as root is the
  unsupported path that produced it.
- A future `--with-password` flag on the deploy, or a non-Hestia first-run wrapper,
  could carry the same bootstrap to other install methods.

## Status

Implemented 2026-06-26. `setup-manager` in `lazysite-users.pl`; wired into the
Hestia deploy; pinned by `t/unit/users/01-user-management.t` (create + group + conf
keys + generated password + idempotent re-run).
