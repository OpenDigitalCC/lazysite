---
id: SM1393
title: "SM1393: the agent roles and the shipped bundles reach a site the seeded mark never reached"
subtitle: "Both adoptions in the users tool ran only where a group record carried the seeded mark. A site bootstrapped before the mark existed carried it on no record and adopted nothing from any release, for ever. A bootstrapped site now adopts once; the mark is read from the manager group, which no adoption writes."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent, from edge testing of 0.16.6 (brief n765)"
area: users
status-note: "SHIPPED (PENDING) on n765: _bootstrapped and _shipped_groups in tools/lazysite-users.pl guard _adopt_added_bundles and _adopt_agent_roles; the mark is read from the manager group. t/unit/users/72. UPGRADE.md note under Unreleased (0.16.7)."
---

# What happened

SM1371 (0.16.6) said the four agent roles - `content-agent`, `data-agent`,
`forms-reader`, `analytics-agent` - appear on a site's first Users or Groups
page load after the upgrade. On the edge instance they did not, after several
loads. The bundles SM1241 and SM1262 adopt on an existing site (`cap-tidy`,
`cap-services`, `cap-maintenance`, `cap-audit-switch`, `ch-files`) were absent
there too, which is the discriminating evidence: the two adoptions share one
guard, and it was the guard that failed.

`_ensure_groups_seeded` calls `_adopt_added_bundles` and `_adopt_agent_roles`
on ordinary use. Both returned before doing anything unless some group record
carried `seeded` - the roles sub for any group, the bundles sub for a group
named in `_default_group_nesting`. The mark was written by SM608 (0.11.3) at
seed time, as the one moment "did this ship?" is known for certain, and SM1118
took it as the sign of "a site with the shipped role layer". A site
bootstrapped before 0.11.3, or whose manager group was written by
`_migrate_conf_manager_groups` (from `lazysite.conf`'s `manager_groups`, which
writes no mark), carries the mark on no record. On such a store "absent" says
nothing, and both adoptions read it as "nothing shipped here": the site adopted
no later release's bundles or roles, ever.

# The guard, from the code's own history

`git log -S'seeded => 1'` names SM644, SM667, SM906, SM1118 and SM1371. SM608
wrote the mark so the Groups page could tell a shipped group from an operator's
(the two carry different risk on rename and delete). SM1118 used it to nest a
new bundle only into shipped roles, "so a pre-roles site is left as it is", and
SM1241 added "only on a site that already has the bundle layer". SM1262
(53a699041) put the had-record beside it so a deleted bundle never returns:
absent is all the group store says. None of them meant "a site that predates
the mark adopts nothing"; that is what the guard did.

So the guard is now what the brief asked: a BOOTSTRAPPED site - a record with
the `manager` flag, which every bootstrap writes (`setup-sysop` marked, the conf
migration unmarked) - adopts once. What the mark can say on this site is
decided once for both adoptions (`_shipped_groups`), and it is read from the
MANAGER GROUP rather than from any record: the manager group is written first
and no adoption ever touches it, so the answer is the same before an adoption
and after. Reading "any marked record" instead would flip a pre-mark store to
"marked" the moment one role was adopted onto it (the adopted record carries
the mark), and the next release's bundle would then take every pre-mark role
for operator-made.

- A store whose manager group carries the mark: shipped = marked. SM608's
  reading stands; an operator's group under a shipped name is never nested into
  or taken for a bundle (t/unit/users/72, subtest 4).
- A store whose manager group does not: shipped = present under its shipped
  name, which is all such a store can say.

SM1262's rules are kept as they were: the bundle layer must be there (one
shipped bundle present) before a bundle is adopted, a bundle is nested only into
shipped roles present, only an absent bundle or role is written, and
`bundles-adopted.json` remembers what was offered - a deleted bundle or role
never returns, and a record that exists and cannot be read adopts nothing and
says so.

One ordering followed from adopting onto older stores. The SM576 `assignable`
backfill fires only on a store where NO record carries the flag, and every
record the adoptions write carries it; a store that predates the flag, adopted
onto first, was then never backfilled and every operator group on it read as a
backend group nobody could be assigned to (t/unit/users/34 and
t/unit/manager/159 caught it at the precheck). `_ensure_groups_seeded` now runs
the backfill before the adoptions; on a store the flag has reached it does
nothing.

# What appears on an older site

The next Users or Groups page load after the upgrade (the manager's
`groups-list`, `users-page` and `users-detail` go through the users tool's
`--api` child, whose reads call `read_group_settings` and so
`_ensure_groups_seeded`), or any users-tool command that seeds first
(`setup-sysop`, `group-add`, `settings`, `verify-credential`): the four agent roles, with no
members; and, where the site has the bundle layer, the bundles it lacks, nested
into the roles present under their shipped names. The audit log records each.

**The CLI `groups` listing does not.** `cmd_groups` reads the store through
`_migrate_group_assignable` and never calls `_ensure_groups_seeded` (it is
listed read-only in the tool's audit table, `%CLI_NO_DIRECT_AUDIT`), so an operator who runs
`lazysite-users.pl groups` after the upgrade sees the roles only after a page
load or another seeding command. Left as it is: making a listing a mutation is a
separate decision, and the question is answered here as the brief asked.

# Other guards of the same shape

Reported, not changed:

- `cmd_group_reset` (SM667) restores only a group whose record carries the mark,
  and `cmd_reset_groups` (SM644) restores "every seeded group" and keeps an
  unmarked one as operator-made. On a pre-mark site neither can put a shipped
  group back. Both are deliberate rules on the mark, and a pre-mark site's
  shipped groups are indistinguishable from an operator's by anything but name.
- The Groups page's "shipped" badge (`seeded` in the group-settings view) reads
  the mark, so a pre-mark site shows no group as shipped.
- Not the same shape, but found at the survey: `cmd_group_create` and
  `cmd_group_settings_set` write the store without seeding first. A store whose
  FIRST write came through them (the file absent until then) exists thereafter
  and the seed branch - which runs only where the file is absent - never runs:
  no roles, no bundles, no nesting. Such a store has no manager group until
  `setup-sysop`, which writes one with the mark; after that this release's
  adoption gives it the roles, and the bundles only once a shipped bundle is
  present, which nothing then provides.

# Tests

t/unit/users/72-the-roles-reach-a-site-the-mark-never-reached.t: a site with
manager groups and no `seeded` on any record gets the four roles and the three
bundles on the next `users-page`, as shipped, with no member, nested into the
roles present; the record remembers them and a second read changes nothing; a
deleted role and a deleted bundle stay deleted; an unreadable record adopts
nothing; on a marked store an operator's unmarked `analysts` is not nested
into; a site with a manager group and no role layer gets the roles and no
bundle; a store with no manager group adopts nothing. With the guard as on
main, subtests 1, 2 and 5 fail. t/unit/users/56, 70 and 39 and
t/integration/321 pass unchanged.
