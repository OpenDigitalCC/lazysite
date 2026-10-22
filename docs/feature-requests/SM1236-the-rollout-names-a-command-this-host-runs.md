---
id: SM1236
title: "SM1236: the rollout names a command this host runs, and the repair after a rebuild"
subtitle: "The 0.16.0 rollout told the operator to run `lazysite check --domain D` on a host where the tarball put no `lazysite` on PATH, and a hint to run v-rebuild-web-domain said nothing of the repair the rebuild makes necessary. Every hint now names the CLI as this host has it, offers repair rather than check --fix, and follows a rebuild with the repair."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager, reading the 0.16.0 stable rollout report and the manual rebuilds after it"
area: installers
status-note: "SHIPPED (PENDING) on n724: cli_cmd and rebuild_hint in the updater, LAZYSITE_CLI to the tools, cli_spelling in check, acl and hestia-domain. t/tools/236."
---

# What happened

- The rollout's findings and failure lines said `lazysite check --domain D`, and the
  CLI's NOT SERVICEABLE line said `lazysite check --domain X --fix`. A host deployed
  from the tarball has no `lazysite` on PATH: the .deb installs it, the tarball does
  not. The release manager also asked why both `check --fix` and `repair` were offered.
- After the rollout a manual `v-rebuild-web-domain USER DOMAIN` reset the docroot to
  2751 and `lazysite/git` to 2775 on dhcf.eu, oca-odoo.com and stuartjmackintosh.com
  (SM270). The repair fixed both, but no hint that names the rebuild said to run it.

# What shipped

- The updater's `cli_cmd` gives `lazysite` when it is on PATH, otherwise
  `perl <stage>/tools/lazysite-cli.pl`, which runs from any directory. Every hint
  in the summary, the verdict and the findings uses it, and the updater exports it as
  `LAZYSITE_CLI` so the deploy and the tools it runs spell it the same way.
- The CLI sets `LAZYSITE_CLI` to the way it was reached (`invoked_as`, SM899) unless a
  caller already set it. Its NOT SERVICEABLE line names `repair --domain X` (check,
  `--fix`, check again) in place of `check --fix`. Its `sites` hint is spelled the same way.
- `lazysite-check.pl`, `lazysite-acl.pl` and `lazysite-hestia-domain.pl` spell their
  hints through `cli_spelling`: `LAZYSITE_CLI`, else `lazysite` on PATH, else the CLI
  beside the tool by path.
- Every hint that sends an operator to `v-rebuild-web-domain` now names the repair
  after it: the updater's template-refresh and vhost lines and the X-Forwarded-For
  failure, the deploy's homepage note, the check's forwarded-trust hint, and the
  hestia-domain template notes.
- `--rebuild` already repairs after rebuilding: it rebuilds each in-scope vhost
  before the deploy, whose permission pass and root `check --fix` put the
  permissions back, and the health phase then runs `repair` on each site. A domain
  it rebuilds because it is on a refreshed template but does not manage (the
  cgi/fcgi flow) gets no deploy and no repair, so the rollout now prints the
  repair command for each such domain. It does not run that repair itself:
  repairing a site outside the run's scope is what SM345 forbids.
- The excluded-domain line names the lister by its path in the stage.

# Not done

- The manager's own messages (`run: lazysite check --fix` in Common.pm, Notices.pm,
  AuditTrail.pm, Private.pm) are shown in the browser, where no command runs. They are
  left as they are.
- `lazysite-check.pl`'s other `--fix` hints say "run with --fix", which is true of
  the command being run.
