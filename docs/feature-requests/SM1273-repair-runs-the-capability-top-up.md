---
id: SM1273
title: "SM1273: lazysite repair runs the capability top-up"
subtitle: "A site whose only warning was a manager group's not-yet-held capability was left \"awaiting your decision\" by lazysite repair, though the SM645 top-up grants it on the next use of the users tool. Repair now runs that top-up before it checks again. A declined capability stays declined."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 25 (2026-10-23), on SM1272's open question"
area: cli
status-note: "SHIPPED (PENDING) on n731: cmd_repair runs lazysite-users.pl --docroot D group-reach <group> for each manager group after --fix and before the re-check, as the site's owner when run as root; --dry-run names the commands and runs none; a failed call is reported and the repair goes on. The check's fix for the SM1272 warning names `repair --domain DOMAIN` first. t/tools/273, t/tools/59."
---

# What was asked

Ruling 25 (2026-10-23): `lazysite repair` runs
`lazysite-users.pl --docroot D group-reach <group>` for each manager group before its
re-check. The SM645 top-up then fills the gap, and the site lands in clean or repaired,
not "awaiting your decision". It never re-grants a declined capability; `--dry-run`
reports that it would run the top-up and runs nothing; a failed users-tool call is
reported and does not stop the repair.

# What shipped

- **`cmd_repair`** (tools/lazysite-cli.pl): for a site that has findings, after the
  doctor's `--fix` and before the re-check, one `group-reach <group>` per manager group.
  The manager groups are read from the site's `auth/groups-settings.json`. Each call runs
  `_ensure_groups_seeded`, and that tops up every manager group with each capability it
  has no decision on. An explicit 0 is a decision, so a declined capability is never
  granted.
- **Who runs it.** Repair runs the check as the user who invoked it. The top-up writes
  the group store, so when repair runs as root it drops to the site's owner with
  `sudo -n -u` (`_as_owner`), as `probe` and `upgrade --all` do. Run as anyone else, it
  runs as that user, as the check does. The ruling said "the same identity repair
  already uses for the check". As root that would have been root writing the store, so
  repair uses the site's owner, which is what the ruling's "as the site user" asks.
- **`--dry-run`** prints "would run the capability top-up: <command>" per manager group
  and runs nothing.
- **A failed call** prints "the capability top-up for <group> did not run (exit N):
  <command> - <its last line>". The repair goes on to the re-check and the tally. So
  does a group store that cannot be read: it is named, and nothing is run.
- **The SM1272 warning's fix** names `<cli> repair --domain DOMAIN (it runs the top-up)`
  first, spelled through SM1236's `cli_spelling`, and keeps `group-reach` as the shell
  fallback.
- The repair POD and docs/OPERATOR.md say what repair now does.

# Tests

- **t/tools/273** (new). The real CLI and the real users tool run in a payload whose
  check is a stand-in: it warns while a manager group lacks a capability, and is
  otherwise clean. The site is made by `setup-sysop`, and sysops is then left without
  `maintenance_access` and with `feedback` declined.
  - After `repair --domain`, sysops holds `maintenance_access`, the re-check is clean,
    and the tally is "0 clean, 1 repaired, 0 awaiting your decision".
  - `feedback` is still 0 after the top-up ran.
  - `--dry-run` names `group-reach sysops`, the group store is byte-identical, and
    nothing is granted.
  - A users tool that exits 3 is reported with its message, and the tally still prints.
- **t/tools/59**: the warning names `repair --domain DOMAIN (it runs the top-up)`.

With tools/lazysite-cli.pl at main, all four t/tools/273 subtests fail.

# Not done

- **A real check in the repair test.** The verdict is the stand-in check's. The real
  check reports more than this on a fixture site, and its wording is t/tools/59's.
- **No sudoers entry is added.** A root repair on a host without the `sudo -n` entry
  reports the top-up as failed and goes on, as `probe` does.
