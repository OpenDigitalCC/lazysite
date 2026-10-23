---
id: SM1304
title: "SM1304: lazysite check names a symbolic link in the served asset mirror"
subtitle: "A link a theme upload planted before 0.16.2 stays after the upgrade, serving what it points at. The check now warns for every symbolic link under lazysite-assets/, naming it and its target and saying to remove it and rotate lazysite/auth/.secret. It never deletes one, and repair does not count the site as repaired."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "ruling 42 (2026-10-23), with the security release SM1303 belongs to"
area: security
status-note: "SHIPPED (0.16.2) on n738: lazysite-check.pl report_asset_links, one WARN per link with the remedy on the line itself; lazysite repair puts a site with one among those needing a human. t/tools/290."
---

# What was asked

Ruling 42: `lazysite check` WARNS on any symbolic link under `lazysite-assets/`,
naming it and telling the operator to remove it and rotate `lazysite/auth/.secret`;
it never deletes. SM1303 stops a theme upload planting one, but a link planted
before 0.16.2 stays in the mirror after the upgrade, still serving what it points
at, and nothing looked. Ruling 43: no host-wide sweep before the release; the
check finds planted links at the deploy.

# What shipped

- **One WARN per link** under the docroot's `lazysite-assets/` (or for
  `lazysite-assets` itself, if it is a link), in the check's run after the
  protected-content check:

      [ warn ] SYMBOLIC LINK in the served asset mirror: lazysite-assets/default/t/x.css -> /srv/site/lazysite/auth/.secret. Anything it points at is public at /lazysite-assets/default/t/x.css. Remove it, and rotate /srv/site/lazysite/auth/.secret

  The remedy is on the line itself, because the Hestia rollout's findings digest
  keeps a `[ warn ]` line and drops the hint under it. The hint spells both
  steps: `rm` the link, then rotate the secret from the manager's Sessions page,
  "Log out all users" (`rotate-auth-secret`), which writes a new one and signs
  every session out. There is no command-line rotation; that action is the
  repo's one way to rotate. A mirror with no link reports an `ok` line.
- **Never removed.** The check, and its `--fix`, leave every link where it is: it
  may be the operator's own, and removing it does not undo what it served.
- **Repair does not count it as fixed.** `lazysite repair` sorts what is left
  after its fix by the doctor's marker: a FAIL needs a human, a warn is a decision
  for later. This warn is neither a fault the repair could fix nor a decision, so
  a site that still has one is counted among those needing a human and the run
  exits 1, which the Hestia rollout's repair tally reads as "need a human" rather
  than clean. The deploy's own health check prints the warning through the
  existing path, with every other finding.

# Tests

- t/tools/290: a clean mirror says so; a planted link is warned with the link, its
  target, its URL and the remedy on the line, and the hint names `rm` and
  `rotate-auth-secret`; two links give two warnings and `--fix` removes neither;
  `lazysite repair` over a payload whose doctor is the real check (its
  asset-mirror lines only, as a scratch site fails on ownership) counts a site
  with no link clean and a site with one as needing a human, exit 1, the link in
  place. With lazysite-check.pl as on main every subtest fails; with
  lazysite-cli.pl as on main the repair subtest fails (the site is "awaiting your
  decision" and the run exits 0).
