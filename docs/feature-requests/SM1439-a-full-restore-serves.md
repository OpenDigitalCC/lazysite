---
id: SM1439
title: "SM1439: a full restore gives a site that serves"
subtitle: "The SM1438 rehearsal found that --restore-full left the cgi-bin entry points unlaid and the serving group unapplied, and ended by telling the sysop to check ownership by hand. Ruling 239: one command does the whole job."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-11
raised-by: "the restore rehearsal on the shipped 0.16.11 tarball (SM1438, n816), ruled on by the release manager (ruling 239); built by the lazysite developer agent on n817"
area: reliability
status-note: "SHIPPED (PENDING): --restore-full lays the engine's entry points from the release it runs, by the code provision uses, takes --cgibin and --serving-group, applies the group and modes and ends with the health check; it refuses before extracting when it cannot lay them. t/tools/628."
---

# What happened

SM1438 restored a full backup onto a new docroot with `install.pl --restore-full`. The content,
the auth store and the conf came back. `lazysite check` on the new docroot then reported
`cgi-bin/lazysite-processor.pl`, `lazysite-auth.pl` and `lazysite-manager-api.pl` missing, and,
without `--group`, 17 group and mode failures. `cmd_restore_full` extracted the docroot only and
ended on "Check file ownership/permissions on the target host".

# The change

`--restore-full` is the whole procedure (ruling 239):

- it lays the engine's entry points (the cgi-bin scripts, and the lib, tools and extensions beside
  the docroot) from the release it runs. The plan is the install plan narrowed to the engine's
  entries and run by the same `execute_plan`; the extension endpoint links and the group and mode
  pass are the subs an install calls (`link_extension_endpoints`, `apply_site_modes`);
- it takes `--cgibin`, required as provision requires it, and `--serving-group`, defaulting as
  provision does;
- it creates the runtime paths, applies the group and modes, and ends with the health check (exit 4
  when the site is not serviceable yet);
- when the entry points cannot be laid it refuses before extracting anything and says what to run
  (ruling 206). The "Check file ownership" line is gone.

`lazysite backups --restore-full` takes `--cgibin`, `--installdir` and `--serving-group` and carries
the exit status.

# Test

`t/tools/628` provisions a scratch site, takes a full backup, destroys the site, restores onto a new
docroot with `--serving-group` set to the test user's own group, and runs the check with that group:
0 failures and the three entry points present. It fails on the code before this change.
