---
id: SM1272
title: "SM1272: the check says a manager group is granted a new capability on the next use"
subtitle: "After the 0.16.1 deploy, edge's check told the operator that sysops had \"not decided\" on maintenance_access and asked them to decide on the Groups page. The SM645 top-up grants it on the next use of the manager or the users tool, so there is nothing to decide. The check now says that, and keeps the decision wording for a gap the top-up does not fill."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the 0.16.1 deploy on edge.explore.lazysite.io (\"manager group(s) have not decided on capabilities this release has: sysops/maintenance_access\"); the release manager's rulings 23 (A: SM685 stands, no top-up at upgrade) and 24 (n731 starts the 0.16.2 batch), 2026-10-23"
area: users
status-note: "SHIPPED (0.16.3) on n731: lazysite-check reports a manager group's absent capability as granted on the next use of the manager or the users tool (the Users, Groups or Config page, or a command such as group-reach), with group-reach as the shell fallback; a gap the top-up does not fill keeps SM496's wording. The SM471 comment is brought up to SM645 and SM685. t/tools/59, t/unit/tools/41."
---

# What was found

The 0.16.1 deploy on edge reported:

    [ warn ] manager group(s) have not decided on capabilities this release has:
    sysops/maintenance_access - added after the group was seeded.

SM1118's ruling (#338) gives `maintenance_access` to sysops. sysops gets it through
SM645's top-up, `_ensure_manager_group_caps` in `tools/lazysite-users.pl`, as a manager
group gets every capability it has no decision on. It does not come through a bundle:
`cap-maintenance` is for site-admins. The top-up runs from `_ensure_groups_seeded`, on
the next use of the users tool: the manager's Users, Groups and Config pages (the Config
page loads `capability-holders`), and commands such as `permissions`, `settings` and
`group-reach`. It does not run at upgrade or on sign-in. SM685 took it off the credential
path, and the release manager accepted that on 2026-09-09. The deploy runs the check before
anything uses the users tool, so an upgraded site shows the gap until the manager is next
used.

The warning dated from SM471 ("reported, not repaired"), from before SM645. It asked
the operator to "Decide in the manager UI ... (grant or dismiss)", but the code had
already decided to grant (ruled 2026-08-27).

# Rulings

The release manager, 2026-10-23: ruling 23 is A. SM685 stands, and nothing tops up at
upgrade. The check should say that a capability the top-up fills is granted on the next
use and name that use, and keep the decision wording where a decision is still needed.

# What shipped

- **`tools/lazysite-check.pl`** splits the absent capabilities of a manager group by the
  top-up's own rule (a manager group, any capability but `api`/`mcp`):
  - **one the top-up fills**: "manager group(s) do not hold capabilities this release
    has yet: sysops/maintenance_access - added after the group was seeded. A manager
    group is granted them on the next use of the manager or the users tool (opening the
    Users, Groups or Config page, or a lazysite-users.pl command such as group-reach);
    nothing to decide, and a capability declined on purpose stays declined". The fix is:
    `perl tools/lazysite-users.pl --docroot DOC group-reach sysops`, as the site user.
  - **anything else** keeps SM496's warning: "have not decided on capabilities", the Groups
    page banner (grant or dismiss), and `group-set` as the shell fallback.
- **An explicit 0 is still a decision.** It does not warn, and is counted in the OK line.
- **The SM471 comment** now says what SM645 repairs, when it runs, and why it does not run
  at upgrade (SM685, kept 2026-10-23).
- **CHANGELOG.** The released 0.16.1 line says "on upgrade too (an upgrade adds the
  `cap-maintenance` bundle)". The new entry corrects it: the operator group and
  site-admins get the capability on the next use of the users tool. The released section
  is not edited.

# Tests

- **t/tools/59**: on a site made by `setup-sysop` with `manage_data` dropped from sysops,
  the check says the group is granted it on the next use, names the Config page, offers
  `group-reach sysops`, and no longer says "have not decided" or "grant or dismiss". A new
  subtest makes the promise true: after the Config page's `capability-holders` call, and
  separately after `group-reach sysops`, the check is clean.
- **t/unit/tools/41**: an absent capability on a manager group gets the new wording; a
  declined one still does not warn. The decision case cannot be produced through a site
  today, because every gap the check sees is on a manager group and in a capability the
  top-up fills. It is held from the source instead: the check's predicate is the top-up's
  rule (both read), what the predicate rejects goes to the decision bucket, and that bucket
  keeps the "have not decided" warning and the banner remedy.

With `tools/lazysite-check.pl` at main, t/tools/59 fails "a site missing one is told" (six
assertions) and t/unit/tools/41 fails both new subtests.

# Not done

- **No top-up at upgrade** (ruling 23).
- **`lazysite repair`** filed a site whose only warning was this one under "awaiting
  your decision". Ruling 25 (2026-10-23) has repair run the top-up, so the site is
  repaired instead: SM1273. The warning's fix names `repair --domain DOMAIN` as the
  simplest route.
