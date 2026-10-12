---
id: SM1024
title: "SM1024: an undecodable groups-settings.json unsecures the manager API"
subtitle: "SM906 made an UNREADABLE store fail closed in Auth::Settings; a store that opens and does not decode still reads as no groups there, which is the mode where every authenticated user is a manager. The render path already treats it as secured."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: found while working SM1023 (WORK-PLAN-0154 U5)
area: security
status-note: "SHIPPED (PENDING): ruled 2026-10-12 \"Fail closed everywhere\"; built on n437 (WORK-PLAN-0154 U6). An undecodable groups-settings.json sets the same fourth state as an unreadable one on every reader, and the processor's acls.json readers treat an undecodable store as a failed load. t/integration/185, 186."
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

# The ruling

Release manager, 2026-10-12: "Fail closed everywhere". A store that opens and
does not decode is answered exactly as one that will not open, on every
reader: the manager answers cannot-tell (the SM906 shape) and refuses until
the file is repaired, and nobody becomes a manager or an operator by a broken
file.

# What was built (n437, WORK-PLAN-0154 U6)

Reproduced on n436 first (t/integration/185): with a truncated store, a
signed-in account in no group was served the manager's account list (200),
was an Auth::Acl operator, and `site_grants_manager` answered 0.

- `read_group_settings` sets the fourth state for a store that does not decode
  to an object (a truncation, a JSON array, an empty file), and
  `group_settings_undecodable()` says which fault it was. The manager API's
  cookie and token doors and MCP refuse with kind `cannot-tell` (503, MCP
  -32003) naming `lazysite/auth/groups-settings.json`; the sentence says the
  file does not decode and that the repair is to the JSON, since `--fix`
  repairs modes. `site_grants_manager` answers secured,
  `group_is_assignable` strict, `Auth::Acl::_is_operator` no.
- `write_group_settings` refuses to write over a store whose last read failed
  (unreadable or undecodable), as SM785 does for user-settings.json: every
  writer is a read-modify-write of the whole map.
- The processor's `_acl_governed` and `_acl_governing_key` treat an acls.json
  that does not decode as a failed load. They decoded with `|| {}` and CACHED
  the empty map, so a later `_acl_allows_read` in the same request found no
  rules and allowed every path, and registry builds listed governed pages
  (t/integration/186).
- The MCP audit's `acl_keys_unreadable` is set for an undecodable acls.json
  (t/unit/mcp/19), and the scheduler refuses a job account by naming an
  undecodable group store rather than "does not hold run_jobs"
  (t/unit/daemon/10). `lazysite check`'s FAIL now says the manager refuses
  until the file is repaired (t/tools/126).

# Inventory of readers

groups-settings.json:

| Reader | Before | Decision |
| --- | --- | --- |
| lib/Lazysite/Auth/Settings.pm `read_group_settings` | undecodable read as no groups, flag clear | FIXED: sets the fourth state |
| Settings.pm `site_grants_manager`, `group_is_assignable`, `auth_cannot_tell`, `groups_grant_cap`, `_group_caps`, `_group_closure` | followed the reader | follow the fixed reader |
| Settings.pm `write_group_settings` | wrote over any store | FIXED: refuses over an unreadable or undecodable one |
| Settings.pm `cannot_tell_refusal` | permission sentence only | FIXED: decode sentence for this store |
| lazysite-manager-api.pl `$site_secured`, cookie cannot-tell gate | unsecured on undecodable | closed through the reader |
| lazysite-auth.pl `_login_is_manager` | every login a manager login | closed through the reader |
| lib/Lazysite/Auth/Acl.pm `_is_operator` | every cookie user an operator | closed through the reader |
| lib/Lazysite/Auth/Verify.pm, lazysite-mcp.pl bearer | verified holding nothing | cannot-tell through the reader |
| tools/lazysite-users.pl (readers, `_die_store_unreadable`, delegate ceiling) | unsecured on undecodable | closed through the reader; decode sentence added |
| lib/Lazysite/Manager/Domains.pm (known-groups check) | names from an empty map | refuses through the flag |
| lib/Lazysite/Manager/Users.pm `_manager_groups_from_settings` | no manager groups | display only; reads empty |
| lib/Lazysite/Daemon/Service/Scheduler.pm job account | "does not hold run_jobs" | FIXED: refused naming the file |
| lazysite-processor/auth.pm `_site_grants_manager` | secured | already closed |
| lazysite-processor/acl.pm `_groups_grant_cap`, `_group_settings` | no capability | already closed |
| tools/lazysite-check.pl | FAIL | FAIL, sentence updated |

The sibling stores:

| Store and reader | Open fails | Decode fails | Decision |
| --- | --- | --- | --- |
| acls.json, processor `_acl_allows_read` | refuse, cached | refuse, cached | already closed |
| acls.json, processor `_acl_governed`, `_acl_governing_key` | governed, cached | not governed, `{}` cached | FIXED: as an open failure |
| acls.json, processor `_acl_is_draft` | not draft | not draft | agree; the read check refuses |
| acls.json, Auth::Acl `_acl_map_or_state` (`gating_for`, `root_gating`) | unknown | unknown | agree |
| acls.json, Auth::Acl `load_acls` (manager per-file ACL) | no rules | no rules | agree; open on both by design (the operator repairs from the manager) - see below |
| acls.json, lazysite-mcp.pl audit | flagged | clean bill | FIXED: flagged |
| user-settings.json, Auth::Settings `read_settings` | unreadable | unreadable | agree (SM778) |
| user-settings.json, Auth::Session `account_disabled` | not disabled | not disabled | agree; see below |
| users, groups (plain text) | flagged (SM906) | no decode step | n/a |
| revoked.json, Auth::Session `session_revoked`, Manager::Sessions `_read_revoked` | nothing revoked, WARN | nothing revoked, WARN | agree; open on both by an earlier decision - see below |
| oauth.json, Auth::OAuth `load_store` | no clients or tokens | no clients or tokens | agree; nothing authenticates |

Three readers answer open-and-decode alike but fail OPEN on both, by earlier
decisions that this ruling's question did not reach. They are not changed
here and are raised for a ruling: Auth::Acl `load_acls` (a non-operator's
per-file ACL check under a broken acls.json allows), `session_revoked`
(a broken revoked.json revokes nothing), and `account_disabled` on the
wrapper's sign-in path (a broken user-settings.json disables nobody; the
API doors already refuse through `auth_cannot_tell`).
