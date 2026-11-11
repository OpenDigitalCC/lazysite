---
id: SM1438
title: "SM1438: the restore rehearsal on the shipped 0.16.11 tarball"
subtitle: "The full disaster cycle for the 0.17.0 stable cycle, run from the shipped tarball (ruling 238): install, backup, destroy, restore onto a new docroot, verify, check."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "the release manager (rulings 237, 238), run by the lazysite developer agent on n816"
area: reliability
status-note: "DONE (11 Nov 2026): restore 91 ms; canary content, auth store and lazysite.conf intact. Backup still lands inside the docroot (SM602). The check on the restored docroot reports the cgi-bin entry points missing. Awaiting the release manager's confirmation."
---

# What was run

The shipped tarball `dist/lazysite-0.16.11.tar.gz` (sha256
`c253ee049ae7c28acc47a79bde39ae9579814765c7b6ef26e680a4b2f0c0bce9`, checked first) was
unpacked into a scratch directory and used alone. The model is the 26 Aug 2026 rehearsal in
docs/RELIABILITY.md.

1. `install.pl --mode provision --serving-group users` onto a scratch docroot. The install's
   own health check ended 45 ok, 2 warnings, 0 failures.
2. A canary page and a sysops account (`lazysite-users.pl setup-sysop --user ...`).
3. `action_backup_create('full')` from the tarball's `Lazysite::Manager::Backups`, 1.1 MB.
4. The backup copied out, the docroot destroyed.
5. `install.pl --restore-full ... --domain` onto a new docroot: rc 0, 91 ms.
6. Verified: the canary page, the account's record in `auth/users` and its sysops
   membership in `auth/groups`, and the new domain in `lazysite.conf`.

# Findings

SM602, as it stands: the full backup is written to `lazysite/backups/` inside the docroot it
backs up. The rehearsal copied it out before destroying the docroot.

`lazysite check` on the restored docroot, with `--group users` naming this host's serving
group: 45 ok, 2 warnings (trusted_proxies, one page without a description), 3 failures:
`cgi-bin/lazysite-processor.pl`, `lazysite-auth.pl` and `lazysite-manager-api.pl` missing.
`--restore-full` extracts the docroot only; the entry points come from a provision or
reinstall on the new host. Without `--group` the check expects `www-data` and adds 17 group
and mode failures that are this host's group.

Both are reported for the release manager to rule on. Nothing was changed to make them pass.
