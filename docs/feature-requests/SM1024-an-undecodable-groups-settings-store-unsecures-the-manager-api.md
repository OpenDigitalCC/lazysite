---
id: SM1024
title: "SM1024: an undecodable groups-settings.json unsecures the manager API"
subtitle: "SM906 made an UNREADABLE store fail closed in Auth::Settings; a store that opens and does not decode still reads as no groups there, which is the mode where every authenticated user is a manager. The render path already treats it as secured."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-12
raised-by: found while working SM1023 (WORK-PLAN-0154 U5)
area: security
status-note: "OPEN, needs a ruling: Auth::Settings::read_group_settings answers {} for an undecodable store without setting the unreadable flag, so site_grants_manager says 0 (unsecured). Proposed: an undecodable store sets the same fourth state as an unreadable one. lazysite check FAILs on it (SM1023)."
---

# What was found

`Lazysite::Auth::Settings::read_group_settings` (lib/Lazysite/Auth/Settings.pm)
sets `$GROUP_SETTINGS_UNREADABLE` only when the open fails. A store that opens
and does not decode to an object returns `{}` with the flag clear, so:

- `site_grants_manager` returns 0. That is the unsecured mode (SM138): the
  manager API (`$site_secured`), `lazysite-auth.pl`'s manager-landing and
  `manage_users` fallbacks, and `Auth::Acl` all treat every authenticated user
  as a manager.
- `group_is_assignable` falls through to "assignable", the SM906 field fault
  for this store.

The render path disagrees. `_site_grants_manager` in lazysite-processor/auth.pm
returns 1 for a store that does not decode ("treating the site as secured"), and
its comment says this matches Auth::Settings. For an unreadable store it does;
for an undecodable one it does not.

Measured on 2026-10-12 with a scratch script setting `$AUTH_DIR` to a temporary
directory, against the n435 tree: `site_grants_manager` is 0 when the store is absent, 0 when it is undecodable
(`{ "sysops": { "ui": 1, "manager": 1 ` truncated) or a JSON array, 1 when it is
valid, and 1 when it is mode 0.

A stray comma in a hand-edited store is a realistic way to reach this, as SM268
H12 said of acls.json.

# Proposed

`read_group_settings` sets the fourth state for a store that does not decode,
as it does for one that will not open. That makes `site_grants_manager` answer
secured, `group_is_assignable` strict, and `auth_cannot_tell` name the store.
The manager then refuses with the "cannot tell" response until the file is
repaired, as it does today for an unreadable store, so the repair is from a
shell.

The same question applies to the users and groups files only for an unreadable
file; they are plain text and have no decode step.

# Why it needs a ruling

The fix changes what an operator sees on a broken store: today the manager
works (unsecured); after it, the manager refuses until the file is repaired.
SM906 ruled that an unknown store is not an unsecured site, and this is the
same reasoning, but it is a change in the manager's behaviour, so it is asked.

# Meanwhile

`lazysite check` reports an undecodable groups-settings.json as a FAIL naming
the file, and says the manager API reads it as no groups (SM1023, t/tools/126).
