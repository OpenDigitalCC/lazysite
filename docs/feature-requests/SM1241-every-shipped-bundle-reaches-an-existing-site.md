---
id: SM1241
title: "SM1241: every shipped bundle reaches an existing site"
subtitle: "Bundles were seeded only when groups-settings.json was absent, so cap-tidy, cap-services and any later bundle reached new installs and never the fleet. SM1118 adopted cap-maintenance alone. Every shipped bundle is adopted now, under the same rules."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-22
raised-by: "the release manager (task #369)"
area: users
status-note: "SHIPPED (0.16.1) on n725: _adopt_added_bundles walks every bundle in the shipped nesting map, and only on a site that already has the bundle layer. t/unit/users/56."
---

# What happened

The cap-* bundles and ch-* channels, and the nesting that makes a role draw on them,
are written once: by `_ensure_groups_seeded`, where `groups-settings.json` is absent. A
bundle a later release added (cap-tidy, cap-services) reached new installs only. An
existing site's site-admins never got housekeeping or the services capability through
the role (#369).

[[SM1118]] added `_adopt_added_bundles` for cap-maintenance only.

# What shipped

`_adopt_added_bundles` (tools/lazysite-users.pl) walks every bundle in the shipped
nesting map (`_default_group_nesting`). These are the cap-* bundles and the ch-*
channels. It runs where SM1118's did: on any ordinary use of the users tool on a site
that has its settings file. The rules are SM1118's:

- A bundle is adopted only when it is **absent**. A bundle that exists, edited or not,
  is never rewritten.
- It is adopted only for the shipped roles (the `seeded` mark) that are **present**, and
  only those roles are nested in it. A bundle whose roles are all absent is not added,
  and a role is never invented. cap-audit-switch, which no role draws on, is never
  adopted.
- No role's own record is touched, and the nesting is written only with the new record.
  A role an operator later takes out of an adopted bundle stays out.

One rule is new: **the site must already have the bundle layer** (one shipped bundle is
present). A site seeded between SM608 and SM631 has shipped roles that hold their
capabilities directly and no bundle. Nesting those roles in every bundle would re-home
its live grants, and SM631 left that to a sysop on purpose. Without this guard, SM1118's
code would add cap-maintenance to such a site.

# Tests

t/unit/users/56 seeds a site with `setup-sysop`, then reshapes the store as an earlier
release left it:

- cap-tidy, cap-services and ch-files removed: each comes back as shipped, drawn on by
  its shipped roles. A role and a bundle an operator edited are unchanged. A role taken
  out of an adopted bundle stays out.
- analysts removed with cap-audit, cap-analytics and cap-audit-switch: cap-audit stays
  absent, cap-analytics comes back for agent-ai and mcp-ai only, and cap-audit-switch
  stays absent.
- every bundle removed: nothing is added and no membership changes.

With the change reverted, 13 of its 23 assertions fail. t/integration/321 (SM1118)
still passes.

# Not done

- **A bundle an operator deleted comes back.** Absent is all the store says. A site
  that never had cap-tidy and a site whose operator deleted it look the same, so the
  next use of the tool adopts it again, with its shipped roles. SM1118 already did this
  for cap-maintenance, and it now applies to every bundle, including the ch-* channels.
  A deleted ch-files gives WebDAV back to content-editors, design-team and site-admins.
  Ruled 2026-10-22: adopt once. Fixed by [[SM1262]].
