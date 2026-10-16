---
id: SM1023
title: "SM1023: lazysite check tells an auth store it cannot read from one that is absent"
subtitle: "Run as an account outside the site group, the check called the manager unconfigured; as root it said bootstrapped. Absent, unreadable and undecodable are now three answers."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 U5, seen on sites.lazysite.io after the 0.15.4 upgrade
area: tools
status-note: "SHIPPED (0.15.5): absent is the unconfigured manager; unreadable is a WARN naming the file and user; undecodable is a FAIL naming the file - for groups-settings.json, auth/users and auth/groups, lazysite.conf and acls.json; --check-acl skips a store it cannot read (t/tools/126). Landed 372aef0f."
---

# What was wrong

On sites.lazysite.io after the 0.15.4 upgrade, `lazysite check` run as an
account outside the site group said "no group grants manager access - the
manager is unconfigured"; run as root it said "manager bootstrapped".
groups-settings.json was read with `|| {}`, so a store the run could not open
read as an empty one.

# What it does now

- An absent store is the unconfigured manager.
- One this run cannot open is a WARN naming the file and the user, saying the
  manager state is unknown and to run as root or the site user.
- One that does not decode is a FAIL naming the file.

The same rule covers the manager-account verdict (auth/users, auth/groups),
`manager: enabled` (lazysite.conf) and acls.json: unreadable is a WARN;
undecodable is a FAIL, since the renderer refuses every page it checks against
the ACL. `--check-acl` no longer starts from an acls.json it cannot read or
decode, which it would have rewritten from an empty map.

Test: t/tools/126.

# Found on the way

An undecodable groups-settings.json was read as unsecured by Auth::Settings
(the manager API and sign-in) and as secured by the render path. That was
filed and fixed as SM1024.

# Note

This filing was written on 2026-10-13, after the change landed: the branch
carried a CHANGELOG entry but no filing, which the 0.15.5 release gate's
lint 26 found. The text is taken from the landed commit and the CHANGELOG
entry.
